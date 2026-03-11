defmodule Nex.Agent.Tool.Reflect do
  @moduledoc """
  Self-reflection tool - lets the agent read its own source code and version history.
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Evolution
  alias Nex.Agent.Tool.CustomTools

  def name, do: "reflect"

  def description,
    do: "Read the source code of any agent module for understanding and improvement."

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
            enum: ["source", "versions", "diff", "list_modules"],
            description:
              "source: view current code, versions: list history, diff: compare versions, list_modules: list all evolvable modules"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => "list_modules"}, _ctx) do
    modules = Evolution.list_evolvable_modules()

    formatted =
      modules
      |> Enum.map_join("\n", fn m ->
        name = m |> to_string() |> String.replace_prefix("Elixir.", "")
        if CustomTools.custom_module?(m), do: "- #{name} (custom tool)", else: "- #{name}"
      end)

    {:ok, "Evolvable modules (#{length(modules)}):\n#{formatted}"}
  end

  def execute(%{"action" => "source", "module" => module_str}, _ctx) do
    module = String.to_existing_atom("Elixir.#{module_str}")

    case Evolution.get_source(module) do
      {:ok, source} -> {:ok, "# #{module_str}\n\n```elixir\n#{source}\n```"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "versions", "module" => module_str}, _ctx) do
    module = String.to_existing_atom("Elixir.#{module_str}")

    versions = Evolution.list_versions(module)

    if versions == [] do
      {:ok, "No evolution history for #{module_str}"}
    else
      formatted =
        Enum.map_join(versions, "\n", fn v ->
          "- #{v.id} (#{v.timestamp})"
        end)

      {:ok, "Versions for #{module_str}:\n#{formatted}"}
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "diff", "module" => module_str, "code" => new_code}, _ctx) do
    module = String.to_existing_atom("Elixir.#{module_str}")
    diff = Evolution.diff(module, new_code)
    {:ok, diff}
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "diff"}, _ctx),
    do: {:error, "diff requires module and code parameters"}

  def execute(%{"action" => "source"}, _ctx), do: {:error, "source requires module parameter"}
  def execute(%{"action" => "versions"}, _ctx), do: {:error, "versions requires module parameter"}

  def execute(_args, _ctx),
    do: {:error, "action is required (source, versions, diff, list_modules)"}
end
