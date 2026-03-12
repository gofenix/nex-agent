defmodule Nex.Agent.Tool.ToolDelete do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Tool.CustomTools

  def name, do: "tool_delete"
  def description, do: "Delete a workspace custom tool from the TOOL layer."
  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Custom tool name"}
        },
        required: ["name"]
      }
    }
  end

  def execute(%{"name" => name}, _ctx) do
    case CustomTools.delete(name) do
      :ok ->
        {:ok, %{status: "deleted", name: name, message: "Custom tool '#{name}' deleted."}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_args, _ctx), do: {:error, "name is required"}
end
