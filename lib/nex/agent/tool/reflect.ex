defmodule Nex.Agent.Tool.Reflect do
  @moduledoc """
  Self-reflection tool - lets the agent read its own source code, version history,
  and evolution status.
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.{CodeUpgrade, Evolution}

  def name, do: "reflect"

  def description,
    do: "Inspect CODE-layer source modules, version history, diffs, and evolution cycle status."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          module: %{type: "string", description: "Module name to inspect (e.g. Nex.Agent.Runner)"},
          action: %{
            type: "string",
            enum: [
              "source",
              "versions",
              "diff",
              "list_modules",
              "evolution_status",
              "trigger_evolution",
              "evolution_history"
            ],
            description:
              "source: view current code, versions: list history, diff: compare versions, " <>
                "list_modules: list all upgradable modules, " <>
                "evolution_status: show recent evolution activity, " <>
                "trigger_evolution: manually run an evolution cycle, " <>
                "evolution_history: show evolution audit trail"
          }
        },
        required: ["action"]
      }
    }
  end

  # ── Evolution actions ──

  def execute(%{"action" => "evolution_status"}, ctx) do
    workspace = Map.get(ctx, :workspace)
    events = Evolution.recent_events(workspace: workspace)
    signals = Evolution.read_signals(workspace: workspace)

    events_text =
      if events == [] do
        "No evolution events recorded yet."
      else
        events
        |> Enum.take(10)
        |> Enum.map_join("\n", fn e ->
          "- [#{Map.get(e, "timestamp", "?")}] #{Map.get(e, "event", "?")} #{inspect(Map.get(e, "payload", %{}))}"
        end)
      end

    signals_text =
      if signals == [] do
        "No pending signals."
      else
        "#{length(signals)} pending signal(s):\n" <>
          (signals
           |> Enum.take(10)
           |> Enum.map_join("\n", fn s ->
             "- [#{Map.get(s, "source", "?")}] #{Map.get(s, "signal", "")}"
           end))
      end

    {:ok,
     """
     ## Evolution Status

     ### Recent Events
     #{events_text}

     ### Pending Signals
     #{signals_text}
     """}
  end

  def execute(%{"action" => "trigger_evolution"}, ctx) do
    workspace = Map.get(ctx, :workspace)
    provider = Map.get(ctx, :provider, :anthropic)
    model = Map.get(ctx, :model, "claude-sonnet-4-20250514")
    api_key = Map.get(ctx, :api_key)
    base_url = Map.get(ctx, :base_url)

    case Evolution.run_evolution_cycle(
           workspace: workspace,
           scope: :daily,
           provider: provider,
           model: model,
           api_key: api_key,
           base_url: base_url
         ) do
      {:ok, result} ->
        {:ok,
         """
         ## Evolution Cycle Completed

         - Soul updates applied: #{result.soul_updates}
         - Memory updates applied: #{result.memory_updates}
         - Skill drafts created: #{result.skill_candidates}
         """}

      {:error, reason} ->
        {:error, "Evolution cycle failed: #{inspect(reason)}"}
    end
  end

  def execute(%{"action" => "evolution_history"}, ctx) do
    workspace = Map.get(ctx, :workspace)
    events = Evolution.recent_events(workspace: workspace)

    if events == [] do
      {:ok, "No evolution history yet. Run `trigger_evolution` or wait for automatic cycles."}
    else
      formatted =
        events
        |> Enum.map_join("\n\n", fn e ->
          event = Map.get(e, "event", "?")
          ts = Map.get(e, "timestamp", "?")
          payload = Map.get(e, "payload", %{})

          case event do
            "evolution.soul_updated" ->
              "**[#{ts}] Soul Updated**\nPrinciple: #{Map.get(payload, "principle", "?")}"

            "evolution.memory_updated" ->
              "**[#{ts}] Memory Updated**\nContent: #{Map.get(payload, "content", "?")}"

            "evolution.skill_drafted" ->
              "**[#{ts}] Skill Drafted**\nName: #{Map.get(payload, "name", "?")}\nDescription: #{Map.get(payload, "description", "?")}"

            "evolution.code_hint" ->
              "**[#{ts}] Code Hint**\n#{Map.get(payload, "hint", "?")}"

            "evolution.cycle_completed" ->
              "**[#{ts}] Cycle Completed**\nSoul: #{Map.get(payload, "soul_updates", 0)}, Memory: #{Map.get(payload, "memory_updates", 0)}, Skills: #{Map.get(payload, "skill_candidates", 0)}"

            _ ->
              "**[#{ts}] #{event}**\n#{inspect(payload)}"
          end
        end)

      {:ok, "## Evolution History\n\n#{formatted}"}
    end
  end

  # ── Code inspection actions ──

  def execute(%{"action" => "list_modules"}, _ctx) do
    modules =
      CodeUpgrade.list_upgradable_modules()
      |> Enum.reject(&custom_tool_module?/1)

    formatted =
      modules
      |> Enum.map_join("\n", fn m ->
        name = m |> to_string() |> String.replace_prefix("Elixir.", "")
        "- #{name}"
      end)

    {:ok, "Upgradable modules (#{length(modules)}):\n#{formatted}"}
  end

  def execute(%{"action" => "source", "module" => module_str}, _ctx) do
    with :ok <- reject_custom_module(module_str) do
      module = String.to_existing_atom("Elixir.#{module_str}")

      case CodeUpgrade.get_source(module) do
        {:ok, source} -> {:ok, "# #{module_str}\n\n```elixir\n#{source}\n```"}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "versions", "module" => module_str}, _ctx) do
    with :ok <- reject_custom_module(module_str) do
      module = String.to_existing_atom("Elixir.#{module_str}")

      versions = CodeUpgrade.list_versions(module)

      if versions == [] do
        {:ok, "No evolution history for #{module_str}"}
      else
        formatted =
          Enum.map_join(versions, "\n", fn v ->
            "- #{v.id} (#{v.timestamp})"
          end)

        {:ok, "Versions for #{module_str}:\n#{formatted}"}
      end
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "diff", "module" => module_str, "code" => new_code}, _ctx) do
    with :ok <- reject_custom_module(module_str) do
      module = String.to_existing_atom("Elixir.#{module_str}")
      diff = CodeUpgrade.diff(module, new_code)
      {:ok, diff}
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "diff"}, _ctx),
    do: {:error, "diff requires module and code parameters"}

  def execute(%{"action" => "source"}, _ctx), do: {:error, "source requires module parameter"}
  def execute(%{"action" => "versions"}, _ctx), do: {:error, "versions requires module parameter"}

  def execute(_args, _ctx),
    do:
      {:error,
       "action is required (source, versions, diff, list_modules, evolution_status, trigger_evolution, evolution_history)"}

  defp reject_custom_module(module_str) do
    if custom_tool_module?(module_str) do
      {:error,
       "reflect is for CODE-layer framework modules. For workspace custom tools, inspect/edit files in workspace/tools."}
    else
      :ok
    end
  end

  defp custom_tool_module?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Nex.Agent.Tool.Custom.")
  end

  defp custom_tool_module?(module_str) when is_binary(module_str) do
    String.starts_with?(module_str, "Nex.Agent.Tool.Custom.")
  end

  defp custom_tool_module?(_), do: false
end
