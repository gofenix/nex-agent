defmodule Nex.Agent.Tool.ToolCreate do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Tool.CustomTools

  def name, do: "tool_create"

  def description,
    do: "Create a new workspace custom Elixir tool in the TOOL layer under workspace/tools."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Tool name in snake_case"},
          description: %{type: "string", description: "What this tool does"},
          content: %{
            type: "string",
            description: "Complete Elixir module source code implementing the tool"
          },
          parameters: %{type: "object", description: "Reserved for future tool generators"}
        },
        required: ["name", "description", "content"]
      }
    }
  end

  def execute(%{"name" => name, "description" => description, "content" => content}, ctx) do
    created_by =
      Map.get(ctx, :created_by) ||
        Map.get(ctx, "created_by") ||
        "agent"

    case CustomTools.create(name, description, content, created_by: created_by) do
      {:ok, tool} ->
        {:ok,
         %{
           status: "created",
           tool: tool,
           message: "Custom tool '#{name}' created and registered."
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_args, _ctx), do: {:error, "name, description, and content are required"}
end
