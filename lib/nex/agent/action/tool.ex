defmodule Nex.Agent.Action.Tool do
  @moduledoc false

  alias Nex.Agent.Tool.CustomTools

  @spec execute(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute(payload, ctx) do
    name = Map.get(payload, "name")
    description = Map.get(payload, "description")
    content = Map.get(payload, "content")

    created_by =
      Map.get(ctx, :created_by) ||
        Map.get(ctx, "created_by") ||
        "agent"

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, "tool action requires name"}

      not is_binary(description) or String.trim(description) == "" ->
        {:error, "tool action requires description"}

      not is_binary(content) or String.trim(content) == "" ->
        {:error, "tool action requires content"}

      true ->
        case CustomTools.create(name, description, content, created_by: created_by) do
          {:ok, tool} ->
            {:ok, %{created: true, name: name, tool: tool}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
