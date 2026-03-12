defmodule Nex.Agent.Tool.MemoryWrite do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Memory

  def name, do: "memory_write"

  def description do
    """
    Persist important long-term information to workspace memory.

    Use this when you learn something that should survive future sessions.

    Save to:
    - target=user: stable information about the user, preferences, communication style, timezone, role
    - target=memory: environment facts, project conventions, workflow lessons, important context

    Prefer this after meaningful user corrections, durable discoveries, or complex tasks.
    Skip one-off outputs, temporary data, and facts that can be trivially rediscovered.
    """
  end

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["add", "replace", "remove"],
            description: "How to update memory"
          },
          target: %{
            type: "string",
            enum: ["memory", "user"],
            description: "Which persistent store to update"
          },
          content: %{
            type: "string",
            description: "Memory content for add/replace"
          },
          old_text: %{
            type: "string",
            description: "Stable substring to replace or remove"
          }
        },
        required: ["action", "target"]
      }
    }
  end

  def execute(%{"action" => action, "target" => target} = args, ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")

    case Memory.apply_memory_write(
           action,
           target,
           Map.get(args, "content"),
           Map.get(args, "old_text"),
           workspace: workspace
         ) do
      {:ok, %{target: saved_target, action: saved_action}} ->
        {:ok, "Memory #{saved_action} saved to #{saved_target}."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_args, _ctx), do: {:error, "action and target are required"}
end
