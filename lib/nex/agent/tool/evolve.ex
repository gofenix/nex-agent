defmodule Nex.Agent.Tool.Evolve do
  @moduledoc """
  Unified self-evolution tool.
  """
  @behaviour Nex.Agent.Tool.Behaviour
  alias Nex.Agent.Evolve

  def name, do: "evolve"

  def description,
    do:
      "Unified evolution entrypoint. Reflect on the problem, select the right layer (memory, skill, tool, soul, or code), and apply the action."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          request: %{
            type: "string",
            description: "Natural-language evolution request used for automatic reflection"
          },
          target_layer: %{
            type: "string",
            enum: ["soul", "memory", "skill", "tool", "code", "none"],
            description: "Explicit target layer. If omitted, evolve reflects and chooses automatically."
          },
          action_type: %{
            type: "string",
            description: "Explicit action type such as update_memory, create_skill, create_tool, update_soul, or patch_code"
          },
          reason: %{type: "string", description: "Why this change is needed"},
          payload: %{
            type: "object",
            description: "Structured payload for the selected layer"
          },
          module: %{
            type: "string",
            description: "Legacy helper for code actions; merged into payload.module"
          },
          code: %{
            type: "string",
            description: "Legacy helper for code actions; merged into payload.code"
          }
        },
        required: []
      }
    }
  end

  def execute(args, ctx), do: Evolve.execute(args, ctx)
end
