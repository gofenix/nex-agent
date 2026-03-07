defmodule Nex.Agent.Tool.Evolve do
  @moduledoc """
  Self-evolution tool - lets the agent modify and hot-reload any of its own modules.
  """

  @behaviour Nex.Agent.Tool.Behaviour
  require Logger

  alias Nex.Agent.Surgeon

  def name, do: "evolve"
  def description, do: "Modify and hot-reload any agent module. Use to improve tools, fix bugs, or add capabilities. Surgeon auto-protects core modules with canary monitoring."
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
    module = String.to_atom("Elixir.#{module_str}")

    Logger.info("[Evolve] Upgrading #{module_str}: #{reason}")

    surgery_type = if Surgeon.core_module?(module), do: "precision", else: "normal"
    Logger.info("[Evolve] Surgery type: #{surgery_type} for #{module_str}")

    case Surgeon.upgrade(module, code, reason: reason) do
      {:ok, version} ->
        version_id = Map.get(version, :id, "ok")
        {:ok, "Module #{module_str} upgraded (#{surgery_type} surgery, v#{version_id}). Reason: #{reason}"}

      {:error, error} ->
        {:error, "Evolution failed for #{module_str}: #{error}. Fix the code and try again."}
    end
  end

  def execute(_args, _ctx), do: {:error, "module, code, and reason are required"}
end
