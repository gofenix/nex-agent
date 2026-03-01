defmodule Nex.Agent.Entry do
  @moduledoc """
  Session entry with id/parentId for tree structure.
  """

  defstruct [
    :type,
    :id,
    :parent_id,
    :timestamp,
    :version,
    :message,
    :summary,
    :custom_type,
    data: %{}
  ]

  def new(type, opts \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %__MODULE__{
      type: type,
      id: opts[:id] || generate_id(),
      parent_id: opts[:parent_id],
      timestamp: now,
      version: opts[:version] || 3,
      message: opts[:message],
      summary: opts[:summary],
      custom_type: opts[:custom_type],
      data: opts[:data] || %{}
    }
  end

  def new_session(project_id) do
    new(:session, %{data: %{project_id: project_id}})
  end

  def new_message(parent_id, message, tool_call_id \\ nil) do
    msg =
      if tool_call_id do
        Map.put(message, :toolCallId, tool_call_id)
      else
        message
      end

    new(:message, %{parent_id: parent_id, message: msg})
  end

  def new_model_change(parent_id, provider, model) do
    new(:model_change, %{
      parent_id: parent_id,
      data: %{provider: provider, model: model}
    })
  end

  def new_compaction(parent_id, summary, tokens_before) do
    new(:compaction, %{
      parent_id: parent_id,
      summary: summary,
      data: %{tokens_before: tokens_before}
    })
  end

  def new_label(parent_id, target_id, label) do
    new(:label, %{
      parent_id: parent_id,
      data: %{target_id: target_id, label: label}
    })
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower)
  end

  def to_json(entry) do
    map = Map.from_struct(entry) |> Map.drop([:__struct__])
    Jason.encode!(map)
  end

  def from_json(json) do
    case Jason.decode(json) do
      {:ok, map} ->
        atom_map =
          for {key, val} <- map, into: %{} do
            atom_key = String.to_existing_atom(key)

            converted_val =
              if atom_key == :type and is_binary(val) do
                String.to_existing_atom(val)
              else
                val
              end

            {atom_key, converted_val}
          end

        {:ok, struct(__MODULE__, atom_map)}

      error ->
        error
    end
  rescue
    ArgumentError -> {:error, :invalid_entry_data}
  end
end
