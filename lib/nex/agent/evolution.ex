defmodule Nex.Agent.Evolution do
  @moduledoc """
  Evolution engine — closes the loop from history/signals to soul/memory/skill updates.

  The cycle has three stages:
  1. Gather context (HISTORY.md, MEMORY.md, SOUL.md, skills, accumulated signals)
  2. LLM-powered reflection (structured tool call producing an evolution report)
  3. Apply updates with guardrails (soul, memory, skill drafts, audit)
  """

  require Logger

  alias Nex.Agent.{Audit, Memory, Skills, Workspace}

  @evolution_counter_file ".evolution_counter"
  @patterns_file "patterns.jsonl"
  @consolidations_per_evolution 5

  # ── Public API ──

  @doc """
  Run a full evolution cycle.

  Options:
  - `:scope` — `:daily`, `:weekly`, or `:consolidation` (controls analysis depth)
  - `:workspace` — workspace root
  - `:provider`, `:model`, `:api_key`, `:base_url` — LLM config
  - `:llm_call_fun` — override for testing
  """
  @spec run_evolution_cycle(keyword()) :: {:ok, map()} | {:error, term()}
  def run_evolution_cycle(opts \\ []) do
    scope = Keyword.get(opts, :scope, :daily)
    workspace_opts = workspace_opts(opts)

    Logger.info("[Evolution] Starting #{scope} evolution cycle")
    Audit.append("evolution.cycle_started", %{scope: scope}, workspace_opts)

    with {:ok, context} <- gather_context(scope, workspace_opts),
         {:ok, report} <- run_reflection(context, scope, opts),
         {:ok, applied} <- apply_updates(report, workspace_opts) do
      Audit.append(
        "evolution.cycle_completed",
        %{
          scope: scope,
          soul_updates: length(Map.get(report, "soul_updates", [])),
          memory_updates: length(Map.get(report, "memory_updates", [])),
          skill_candidates: length(Map.get(report, "skill_candidates", [])),
          code_hints: length(Map.get(report, "code_upgrade_hints", []))
        },
        workspace_opts
      )

      Logger.info("[Evolution] #{scope} cycle completed: #{inspect(applied)}")
      {:ok, applied}
    else
      {:error, reason} = err ->
        Logger.warning("[Evolution] #{scope} cycle failed: #{inspect(reason)}")
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
        run_evolution_cycle(Keyword.put(opts, :scope, :consolidation))
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

  defp gather_context(scope, workspace_opts) do
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

    # Scope-based history trimming
    history_content =
      case scope do
        :consolidation -> last_n_paragraphs(history, 3)
        :daily -> last_n_paragraphs(history, 10)
        :weekly -> history
      end

    {:ok,
     %{
       history: history_content,
       memory: memory,
       soul: soul,
       skills: skills,
       signals: signals,
       scope: scope
     }}
  end

  # ── Stage 2: LLM Reflection ──

  defp run_reflection(context, scope, opts) do
    signals_text =
      context.signals
      |> Enum.map(fn s ->
        "[#{Map.get(s, "timestamp", "?")}] #{Map.get(s, "source", "?")}: #{Map.get(s, "signal", "")}"
      end)
      |> Enum.join("\n")

    scope_instruction =
      case scope do
        :consolidation ->
          "Focus on the most recent conversation segment only. Look for immediate patterns."

        :daily ->
          "Analyze the last day of activity. Look for emerging patterns and corrections."

        :weekly ->
          "Deep analysis of all history. Look for recurring patterns, skill synthesis opportunities, and soul refinement."
      end

    prompt = """
    You are an evolution analyst for an AI agent. Analyze the agent's recent behavior and produce an evolution report.

    #{scope_instruction}

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

  defp workspace_opts(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> []
      workspace -> [workspace: workspace]
    end
  end
end
