defmodule Nex.Agent.Action.Skill do
  @moduledoc false

  alias Nex.Agent.Skills

  @spec execute(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute(payload, _ctx) do
    name = Map.get(payload, "name")
    description = Map.get(payload, "description")
    content = Map.get(payload, "content")

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, "skill action requires name"}

      not is_binary(description) or String.trim(description) == "" ->
        {:error, "skill action requires description"}

      not is_binary(content) or String.trim(content) == "" ->
        {:error, "skill action requires content"}

      true ->
        case Skills.create(%{name: name, description: description, content: content}) do
          {:ok, skill} ->
            {:ok, %{created: true, name: name, skill: skill}}

          {:error, reason} ->
            {:error, "Error creating skill: #{inspect(reason)}"}
        end
    end
  end
end
