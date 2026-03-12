defmodule Nex.Agent.Tool.UpgradeCode do
  @moduledoc """
  Code upgrade tool - lets the agent modify and hot-reload its own modules.
  """
  @behaviour Nex.Agent.Tool.Behaviour
  require Logger
  alias Nex.Agent.UpgradeManager

  def name, do: "upgrade_code"

  def description,
    do:
      "Upgrade and hot-reload an agent source module. Use this only for CODE-layer changes to internal implementation."

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
    Logger.info("[UpgradeCode] Upgrading #{module_str}: #{reason}")
    surgery_type = if UpgradeManager.core_module?(module), do: "precision", else: "normal"
    Logger.info("[UpgradeCode] Upgrade type: #{surgery_type} for #{module_str}")

    case UpgradeManager.upgrade(module, code, reason: reason) do
      {:ok, %{version: version, hot_reload: hot_reload}} ->
        version_id = Map.get(version, :id, "ok")

        registry_note =
          case Map.get(hot_reload, :registry_swap) do
            %{attempted: true, tool_name: tool_name} -> " Registry updated for #{tool_name}."
            _ -> ""
          end

        message =
          "Module #{module_str} upgraded (#{surgery_type} upgrade, v#{version_id}). Reason: #{reason}. Hot reload restart_required=#{hot_reload.restart_required}.#{registry_note}"

        {:ok,
         %{
           message: message,
           module: module_str,
           upgrade_type: surgery_type,
           version_id: version_id,
           hot_reload: hot_reload
         }}

      {:error, error} ->
        {:error, "Code upgrade failed for #{module_str}: #{error}. Fix the code and try again."}
    end
  end

  def execute(_args, _ctx), do: {:error, "module, code, and reason are required"}
end
