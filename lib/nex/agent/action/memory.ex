defmodule Nex.Agent.Action.Memory do
  @moduledoc false

  alias Nex.Agent.Memory

  @spec execute(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute(payload, _ctx) do
    memory_update = Map.get(payload, "memory_update") || Map.get(payload, "content")
    history_entry = Map.get(payload, "history_entry")

    cond do
      is_binary(memory_update) and String.trim(memory_update) != "" ->
        :ok = Memory.write_long_term(memory_update)

        if is_binary(history_entry) and String.trim(history_entry) != "" do
          :ok = Memory.append_history(history_entry)
        end

        {:ok,
         %{
           updated: true,
           wrote_memory: true,
           wrote_history: is_binary(history_entry) and String.trim(history_entry) != ""
         }}

      is_binary(history_entry) and String.trim(history_entry) != "" ->
        :ok = Memory.append_history(history_entry)
        {:ok, %{updated: true, wrote_memory: false, wrote_history: true}}

      true ->
        {:error, "memory action requires memory_update/content or history_entry"}
    end
  end
end
