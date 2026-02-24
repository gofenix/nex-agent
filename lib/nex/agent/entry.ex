defmodule Nex.Agent.Entry do
  @moduledoc """
  Session entry with id/parentId for tree structure.

  Entry types:
  - session: Session header
  - message: User/assistant/tool messages
  - model_change: Provider/model switch
  - thinking_level_change: Thinking level change
  - compaction: Summary of old messages
  - custom: Extension custom events
  - label: Branch label
  """

  @type entry_type ::
          :session
          | :message
          | :model_change
          | :thinking_level_change
          | :compaction
          | :custom
          | :label

  @type t :: %__MODULE__{
          type: entry_type(),
          id: String.t(),
          parent_id: String.t() | nil,
          timestamp: String.t(),
          version: non_neg_integer(),
          message: map() | nil,
          summary: String.t() | nil,
          custom_type: String.t() | nil,
          data: map()
        }

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

  @spec new(entry_type(), map()) :: t()
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

  @spec new_session(String.t()) :: t()
  def new_session(project_id) do
    new(:session, %{data: %{project_id: project_id}})
  end

  @spec new_message(String.t(), map(), String.t()) :: t()
  def new_message(parent_id, message, tool_call_id \\ nil) do
    msg =
      if tool_call_id do
        Map.put(message, :toolCallId, tool_call_id)
      else
        message
      end

    new(:message, %{parent_id: parent_id, message: msg})
  end

  @spec new_model_change(String.t(), String.t(), String.t()) :: t()
  def new_model_change(parent_id, provider, model) do
    new(:model_change, %{
      parent_id: parent_id,
      data: %{provider: provider, model: model}
    })
  end

  @spec new_compaction(String.t(), String.t(), non_neg_integer()) :: t()
  def new_compaction(parent_id, summary, tokens_before) do
    new(:compaction, %{
      parent_id: parent_id,
      summary: summary,
      data: %{tokens_before: tokens_before}
    })
  end

  @spec new_label(String.t(), String.t(), String.t()) :: t()
  def new_label(parent_id, target_id, label) do
    new(:label, %{
      parent_id: parent_id,
      data: %{target_id: target_id, label: label}
    })
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower)
  end

  @spec to_json(t()) :: String.t()
  def to_json(entry) do
    map = Map.from_struct(entry) |> Map.drop([:__struct__])
    Jason.encode!(map)
  end

  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, struct(__MODULE__, map)}
      error -> error
    end
  end
end
