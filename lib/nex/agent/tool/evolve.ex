defmodule Nex.Agent.Tool.Evolve do
  @moduledoc """
  Self-evolution tool - lets the agent modify and hot-reload any of its own modules.
  """

  @behaviour Nex.Agent.Tool.Behaviour
  require Logger

  alias Nex.Agent.{Evolution, Tool.Registry}

  def name, do: "evolve"
  def description, do: "Modify and hot-reload any agent module. Use to improve tools, fix bugs, or add capabilities."
  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          module: %{type: "string", description: "Full module name (e.g. Nex.Agent.Tool.Bash)"},
          code: %{type: "string", description: "Complete new Elixir source code for the module"},
          reason: %{type: "string", description: "Why this change is needed"}
        },
        required: ["module", "code", "reason"]
      }
    }
  end

  def execute(%{"module" => module_str, "code" => code, "reason" => reason}, _ctx) do
    module = String.to_existing_atom("Elixir.#{module_str}")

    Logger.info("[Evolve] Upgrading #{module_str}: #{reason}")

    case Evolution.upgrade_module(module, code, validate: true) do
      {:ok, version} ->
        # If it's a Tool module, hot-swap in Registry
        maybe_hot_swap_registry(module)

        {:ok, "Module #{module_str} upgraded to version #{version.id}. Reason: #{reason}"}

      {:error, error} ->
        {:error, "Evolution failed for #{module_str}: #{error}. Fix the code and try again."}
    end
  rescue
    ArgumentError ->
      {:error, "Unknown module: #{module_str}. Use reflect tool to check available modules."}
  end

  def execute(_args, _ctx), do: {:error, "module, code, and reason are required"}

  defp maybe_hot_swap_registry(module) do
    if Process.whereis(Registry) do
      Code.ensure_loaded(module)

      if function_exported?(module, :name, 0) do
        tool_name = module.name()
        Registry.hot_swap(tool_name, module)
        Logger.info("[Evolve] Hot-swapped tool #{tool_name} in Registry")
      end
    end
  end
end
