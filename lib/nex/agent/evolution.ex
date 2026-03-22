defmodule Nex.Agent.Evolution do
  @moduledoc """
  Evolution engine — closes the loop from history/signals to soul/memory/skill updates.

  The cycle has three stages:
  1. Gather context (HISTORY.md, MEMORY.md, SOUL.md, skills, accumulated signals)
  2. LLM-powered reflection (structured tool call producing an evolution report)
  3. Apply updates with guardrails (soul, memory, skill drafts, audit)
  """

  require Logger

  alias Nex.Agent.{Audit, Config, Memory, Skills, Workspace}

  @evolution_counter_file ".evolution_counter"
  @patterns_file "patterns.jsonl"
  @consolidations_per_evolution 5
  @quick_history_paragraphs 3
  @routine_history_paragraphs 10

  # ── Public API ──

  @doc """
  Run a full evolution cycle.

  Options:
  - `:trigger` — `:manual`, `:post_consolidation`, `:scheduled_daily`, or `:scheduled_weekly`
  - `:workspace` — workspace root
  - `:provider`, `:model`, `:api_key`, `:base_url` — LLM config
  - `:llm_call_fun` — override for testing
  """
  @spec run_evolution_cycle(keyword()) :: {:ok, map()} | {:error, term()}
  def run_evolution_cycle(opts \\ []) do
    trigger = normalize_trigger(Keyword.get(opts, :trigger, :manual))
    profile = profile_for_trigger(trigger)
    workspace_opts = workspace_opts(opts)
    run_opts = Keyword.merge(opts, resolve_runtime_llm_opts(opts))

    Logger.info("[Evolution] Starting cycle trigger=#{trigger} profile=#{profile}")

    Audit.append(
      "evolution.cycle_started",
      %{trigger: to_string(trigger), profile: to_string(profile)},
      workspace_opts
    )

    with {:ok, context} <- gather_context(profile, workspace_opts),
         {:ok, report} <- run_reflection(context, profile, run_opts),
         {:ok, applied} <- apply_updates(report, workspace_opts) do
      Audit.append(
        "evolution.cycle_completed",
        %{
          trigger: to_string(trigger),
          profile: to_string(profile),
          soul_updates: length(Map.get(report, "soul_updates", [])),
          memory_updates: length(Map.get(report, "memory_updates", [])),
          skill_candidates: length(Map.get(report, "skill_candidates", [])),
          code_hints: length(Map.get(report, "code_upgrade_hints", []))
        },
        workspace_opts
      )

      Logger.info(
        "[Evolution] trigger=#{trigger} profile=#{profile} completed: #{inspect(applied)}"
      )

      {:ok, applied}
    else
      {:error, reason} = err ->
        Logger.warning(
          "[Evolution] trigger=#{trigger} profile=#{profile} failed: #{inspect(reason)}"
        )

        err
    end
  end

  @doc """
  Record an evolution signal to patterns.jsonl.

  Called by the Runner when it detects corrections, errors, or notable events.
  """
  @spec record_signal(map(), keyword()) :: :ok
  def record_signal(signal, opts \\ []) do
    workspace_opts = workspace_opts(opts)
    memory_dir = Workspace.memory_dir(workspace_opts)
    File.mkdir_p!(memory_dir)

    entry = %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => Map.get(signal, :source, "unknown") |> to_string(),
      "signal" => Map.get(signal, :signal, "") |> to_string(),
      "context" => Map.get(signal, :context, %{})
    }

    File.write!(
      Path.join(memory_dir, @patterns_file),
      Jason.encode!(entry) <> "\n",
      [:append]
    )

    :ok
  end

  @doc """
  Read accumulated pattern signals.
  """
  @spec read_signals(keyword()) :: [map()]
  def read_signals(opts \\ []) do
    path = Path.join(Workspace.memory_dir(workspace_opts(opts)), @patterns_file)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, entry} -> [entry]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Clear accumulated pattern signals (called after consumption).
  """
  @spec clear_signals(keyword()) :: :ok
  def clear_signals(opts \\ []) do
    path = Path.join(Workspace.memory_dir(workspace_opts(opts)), @patterns_file)
    if File.exists?(path), do: File.write!(path, "")
    :ok
  end

  @doc """
  Increment consolidation counter and maybe trigger evolution.

  Returns `true` if evolution was triggered.
  """
  @spec maybe_trigger_after_consolidation(keyword()) :: boolean()
  def maybe_trigger_after_consolidation(opts \\ []) do
    workspace_opts = workspace_opts(opts)
    counter_path = Path.join(Workspace.memory_dir(workspace_opts), @evolution_counter_file)

    current =
      case File.read(counter_path) do
        {:ok, content} ->
          case Integer.parse(String.trim(content)) do
            {n, _} -> n
            :error -> 0
          end

        {:error, _} ->
          0
      end

    new_count = current + 1
    File.write!(counter_path, to_string(new_count))

    if rem(new_count, @consolidations_per_evolution) == 0 do
      Logger.info("[Evolution] Triggering evolution after #{new_count} consolidations")

      Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
        run_evolution_cycle(Keyword.put(opts, :trigger, :post_consolidation))
      end)

      true
    else
      false
    end
  end

  @doc """
  Get recent evolution events from the audit log.
  """
  @spec recent_events(keyword()) :: [map()]
  def recent_events(opts \\ []) do
    workspace_opts = workspace_opts(opts)

    Audit.recent(Keyword.put(workspace_opts, :limit, 50))
    |> Enum.filter(fn event ->
      String.starts_with?(Map.get(event, "event", ""), "evolution.")
    end)
  end

  # ── Stage 1: Gather Context ──

  defp gather_context(profile, workspace_opts) do
    history = read_file(Workspace.memory_dir(workspace_opts), "HISTORY.md")
    memory = Memory.read_long_term(workspace_opts)
    soul = read_file(Workspace.root(workspace_opts), "SOUL.md")
    signals = read_signals(workspace_opts)

    skills =
      Skills.list(workspace_opts)
      |> Enum.map(fn s ->
        name = Map.get(s, :name) || Map.get(s, "name", "")
        desc = Map.get(s, :description) || Map.get(s, "description", "")
        "- #{name}: #{desc}"
      end)
      |> Enum.join("\n")

    history_content = history_for_profile(history, profile)

    {:ok,
     %{
       history: history_content,
       memory: memory,
       soul: soul,
       skills: skills,
       signals: signals,
       profile: profile
     }}
  end

  # ── Stage 2: LLM Reflection ──

  defp run_reflection(context, profile, opts) do
    signals_text =
      context.signals
      |> Enum.map(fn s ->
        "[#{Map.get(s, "timestamp", "?")}] #{Map.get(s, "source", "?")}: #{Map.get(s, "signal", "")}"
      end)
      |> Enum.join("\n")

    prompt = """
    You are an evolution analyst for an AI agent. Analyze the agent's recent behavior and produce an evolution report.

    #{instruction_for_profile(profile)}

    ## Current Soul (persona/principles)
    #{if context.soul == "", do: "(empty)", else: context.soul}

    ## Current Memory (long-term facts)
    #{if context.memory == "", do: "(empty)", else: context.memory}

    ## Existing Skills
    #{if context.skills == "", do: "(none)", else: context.skills}

    ## Recent History
    #{if context.history == "", do: "(no recent history)", else: context.history}

    ## Accumulated Signals (corrections, errors, patterns)
    #{if signals_text == "", do: "(no signals)", else: signals_text}

    Call the evolution_report tool with your analysis. Be conservative — only propose changes when there is clear evidence.
    """

    messages = [
      %{
        "role" => "system",
        "content" => "You are an evolution analyst. Call the evolution_report tool."
      },
      %{"role" => "user", "content" => prompt}
    ]

    provider = Keyword.get(opts, :provider, :anthropic)

    llm_opts =
      [
        provider: provider,
        model: Keyword.get(opts, :model, "claude-sonnet-4-20250514"),
        api_key: Keyword.get(opts, :api_key),
        base_url: Keyword.get(opts, :base_url),
        tools: [evolution_report_tool()],
        tool_choice: tool_choice_for(provider, "evolution_report")
      ]
      |> maybe_put_opt(:req_llm_generate_text_fun, Keyword.get(opts, :req_llm_generate_text_fun))

    llm_call_fun =
      Keyword.get(opts, :llm_call_fun, &Nex.Agent.Runner.call_llm_for_consolidation/2)

    case llm_call_fun.(messages, llm_opts) do
      {:ok, report} when is_map(report) ->
        {:ok, report}

      {:error, reason} ->
        {:error, {:llm_failed, reason}}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  defp evolution_report_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "evolution_report",
        "description" => "Submit the evolution analysis report with proposed updates.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "observations" => %{
              "type" => "string",
              "description" => "Summary of patterns observed in recent behavior."
            },
            "soul_updates" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "New principles or values to add to SOUL.md. Only for repeated behavioral patterns that should become policy. Keep concise."
            },
            "memory_updates" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Facts or corrections to add to MEMORY.md. Only for durable knowledge not already captured."
            },
            "skill_candidates" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "name" => %{"type" => "string", "description" => "Snake_case skill name"},
                  "description" => %{"type" => "string", "description" => "One-line description"},
                  "content" => %{"type" => "string", "description" => "Skill markdown content"}
                },
                "required" => ["name", "description", "content"]
              },
              "description" =>
                "Repeated successful multi-step patterns that should become reusable skills."
            },
            "code_upgrade_hints" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Suggested code-level improvements. These are logged but not auto-applied."
            }
          },
          "required" => ["observations"]
        }
      }
    }
  end

  # ── Stage 3: Apply Updates ──

  defp apply_updates(report, workspace_opts) do
    soul_count = apply_soul_updates(report, workspace_opts)
    memory_count = apply_memory_updates(report, workspace_opts)
    skill_count = apply_skill_candidates(report, workspace_opts)
    log_code_hints(report, workspace_opts)

    # Clear consumed signals
    clear_signals(workspace_opts)

    {:ok,
     %{
       soul_updates: soul_count,
       memory_updates: memory_count,
       skill_candidates: skill_count
     }}
  end

  defp apply_soul_updates(report, workspace_opts) do
    updates = Map.get(report, "soul_updates", [])
    if updates == [], do: 0, else: do_apply_soul_updates(updates, workspace_opts)
  end

  defp do_apply_soul_updates(updates, workspace_opts) do
    soul_path = Path.join(Workspace.root(workspace_opts), "SOUL.md")
    current = read_file(Workspace.root(workspace_opts), "SOUL.md")

    new_principles =
      updates
      |> Enum.reject(fn u -> String.contains?(current, String.trim(u)) end)

    if new_principles == [] do
      0
    else
      # Validate via ContextDiagnostics before writing
      additions = Enum.join(new_principles, "\n")

      case Nex.Agent.ContextDiagnostics.validate_write(:soul, additions) do
        :ok ->
          updated =
            if String.trim(current) == "" do
              "# Soul\n\n## Evolved Principles\n\n" <>
                Enum.map_join(new_principles, "\n", &"- #{String.trim(&1)}")
            else
              String.trim_trailing(current) <>
                "\n\n## Evolved Principles\n\n" <>
                Enum.map_join(new_principles, "\n", &"- #{String.trim(&1)}")
            end

          File.write!(soul_path, updated <> "\n")

          Enum.each(new_principles, fn p ->
            Audit.append("evolution.soul_updated", %{principle: String.trim(p)}, workspace_opts)
          end)

          length(new_principles)

        {:error, _reason} ->
          Logger.warning("[Evolution] Soul update rejected by ContextDiagnostics")
          0
      end
    end
  end

  defp apply_memory_updates(report, workspace_opts) do
    updates = Map.get(report, "memory_updates", [])

    Enum.count(updates, fn content ->
      case Memory.apply_memory_write("append", "memory", content, workspace_opts) do
        {:ok, _} ->
          Audit.append(
            "evolution.memory_updated",
            %{content: String.slice(content, 0, 200)},
            workspace_opts
          )

          true

        {:error, _} ->
          false
      end
    end)
  end

  defp apply_skill_candidates(report, workspace_opts) do
    candidates = Map.get(report, "skill_candidates", [])

    Enum.count(candidates, fn candidate ->
      name = Map.get(candidate, "name", "")
      description = Map.get(candidate, "description", "")
      content = Map.get(candidate, "content", "")

      if name == "" or content == "" do
        false
      else
        # Add draft status marker to content
        draft_content = "<!-- status: draft, source: evolution -->\n\n" <> content

        case Skills.create(
               %{name: name, description: "[Draft] " <> description, content: draft_content},
               workspace_opts
             ) do
          {:ok, _} ->
            Audit.append(
              "evolution.skill_drafted",
              %{name: name, description: description},
              workspace_opts
            )

            true

          {:error, reason} ->
            Logger.warning("[Evolution] Failed to create skill #{name}: #{reason}")
            false
        end
      end
    end)
  end

  defp log_code_hints(report, workspace_opts) do
    hints = Map.get(report, "code_upgrade_hints", [])

    Enum.each(hints, fn hint ->
      Audit.append("evolution.code_hint", %{hint: hint}, workspace_opts)
    end)
  end

  # ── Helpers ──

  defp read_file(dir, filename) do
    path = Path.join(dir, filename)

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp last_n_paragraphs(text, n) when is_binary(text) do
    text
    |> String.split(~r/\n\n+/, trim: true)
    |> Enum.take(-n)
    |> Enum.join("\n\n")
  end

  defp tool_choice_for(_provider, _name), do: nil

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_trigger(trigger)
       when trigger in [:manual, :post_consolidation, :scheduled_daily, :scheduled_weekly],
       do: trigger

  defp normalize_trigger(trigger) when is_binary(trigger) do
    case trigger do
      "manual" -> :manual
      "post_consolidation" -> :post_consolidation
      "scheduled_daily" -> :scheduled_daily
      "scheduled_weekly" -> :scheduled_weekly
      _ -> :manual
    end
  end

  defp normalize_trigger(_), do: :manual

  defp profile_for_trigger(:manual), do: :routine
  defp profile_for_trigger(:post_consolidation), do: :quick
  defp profile_for_trigger(:scheduled_daily), do: :routine
  defp profile_for_trigger(:scheduled_weekly), do: :deep

  defp history_for_profile(history, :quick),
    do: last_n_paragraphs(history, @quick_history_paragraphs)

  defp history_for_profile(history, :routine),
    do: last_n_paragraphs(history, @routine_history_paragraphs)

  defp history_for_profile(history, :deep), do: history

  defp instruction_for_profile(:quick) do
    "Focus on the most recent conversation segment only. Look for immediate patterns."
  end

  defp instruction_for_profile(:routine) do
    "Analyze the last day of activity. Look for emerging patterns and corrections."
  end

  defp instruction_for_profile(:deep) do
    "Deep analysis of all history. Look for recurring patterns, skill synthesis opportunities, and soul refinement."
  end

  defp workspace_opts(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> []
      workspace -> [workspace: workspace]
    end
  end

  defp resolve_runtime_llm_opts(opts) do
    config = Config.load(config_opts(opts))
    provider = Keyword.get(opts, :provider, config.provider)
    provider_name = provider_name(provider)

    [
      provider: Config.provider_to_atom(provider),
      model: Keyword.get(opts, :model, config.model),
      api_key: Keyword.get(opts, :api_key) || Config.get_api_key(config, provider_name),
      base_url: Keyword.get(opts, :base_url) || Config.get_base_url(config, provider_name)
    ]
  end

  defp provider_name(provider) when is_binary(provider), do: provider
  defp provider_name(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp config_opts(opts) do
    case Keyword.get(opts, :config_path) do
      nil -> []
      config_path -> [config_path: config_path]
    end
  end
end
