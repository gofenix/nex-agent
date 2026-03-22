defmodule Nex.Agent.Session do
  @moduledoc """
  Simple session management - stores messages as list, persists to JSONL.
  """

  alias Nex.Agent.Workspace

  defstruct [
    :key,
    :created_at,
    :updated_at,
    :metadata,
    messages: [],
    last_consolidated: 0
  ]

  @type t :: %__MODULE__{
          key: String.t(),
          messages: [map()],
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          metadata: map(),
          last_consolidated: non_neg_integer()
        }

  @doc false
  @spec workspace_path(keyword()) :: String.t()
  def workspace_path(opts \\ []) do
    Workspace.root(opts)
  end

  @doc false
  @spec sessions_dir(keyword()) :: String.t()
  def sessions_dir(opts \\ []) do
    Path.join(workspace_path(opts), "sessions")
  end

  @doc false
  @spec session_dir(String.t(), keyword()) :: String.t()
  def session_dir(key, opts \\ []) do
    Path.join([sessions_dir(opts), safe_filename(key)])
  end

  @doc false
  @spec messages_path(String.t(), keyword()) :: String.t()
  def messages_path(key, opts \\ []) do
    Path.join(session_dir(key, opts), "messages.jsonl")
  end

  @doc """
  Create a new session with key (e.g. "telegram:123456").
  """
  @spec new(String.t()) :: t()
  def new(key) do
    now = DateTime.utc_now()

    %__MODULE__{
      key: key,
      messages: [],
      created_at: now,
      updated_at: now,
      metadata: %{},
      last_consolidated: 0
    }
  end

  @doc """
  Add a message to the session.
  """
  @spec add_message(t(), String.t(), String.t(), keyword()) :: t()
  def add_message(%__MODULE__{} = session, role, content, opts \\ []) do
    tool_calls = Keyword.get(opts, :tool_calls)

    # Skip empty assistant messages with no tool_calls
    if role == "assistant" and (content == nil or content == "") and
         (tool_calls == nil or tool_calls == []) do
      session
    else
      extra =
        opts
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

      msg =
        %{
          "role" => role,
          "content" => sanitize_message_content(content),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
        |> Map.merge(extra)

      %{session | messages: session.messages ++ [msg], updated_at: DateTime.utc_now()}
    end
  end

  @doc """
  Get history for LLM - unconsolidated messages, aligned to user turn.
  """
  @spec get_history(t(), non_neg_integer()) :: [map()]
  def get_history(%__MODULE__{} = session, max_messages \\ 500) do
    unconsolidated = Enum.drop(session.messages, session.last_consolidated)
    sliced = Enum.take(unconsolidated, -max_messages)
    slice_start = max(length(unconsolidated) - length(sliced), 0)

    # Align to start of a complete turn (user message).
    # Drop leading assistant/tool messages that are mid-turn fragments.
    {aligned, aligned_start} =
      case Enum.find_index(sliced, fn m -> Map.get(m, "role") == "user" end) do
        nil ->
          {sliced, slice_start}

        idx ->
          {Enum.drop(sliced, idx), slice_start + idx}
      end

    unconsolidated
    |> repair_leading_tool_boundary(aligned, aligned_start)
    |> Enum.map(&sanitize_history_entry/1)
  end

  defp repair_leading_tool_boundary(_messages, [], _start_idx), do: []

  defp repair_leading_tool_boundary(messages, window, start_idx) do
    if tool_message?(hd(window)) do
      tool_ids = leading_tool_call_ids(window)

      case find_matching_assistant_before(messages, start_idx, tool_ids) do
        nil -> Enum.drop_while(window, &tool_message?/1)
        assistant -> [assistant | window]
      end
    else
      window
    end
  end

  defp leading_tool_call_ids(window) do
    window
    |> Enum.take_while(&tool_message?/1)
    |> Enum.map(&Map.get(&1, "tool_call_id"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp find_matching_assistant_before(_messages, start_idx, _tool_ids) when start_idx <= 0,
    do: nil

  defp find_matching_assistant_before(messages, start_idx, tool_ids) do
    candidate =
      messages
      |> Enum.take(start_idx)
      |> Enum.reverse()
      |> Enum.drop_while(&tool_message?/1)
      |> List.first()

    if assistant_message_with_tool_calls?(candidate, tool_ids), do: candidate, else: nil
  end

  defp assistant_message_with_tool_calls?(%{"role" => "assistant"} = message, tool_ids) do
    message_tool_ids =
      message
      |> Map.get("tool_calls", [])
      |> Enum.map(fn tool_call -> Map.get(tool_call, "id") || Map.get(tool_call, :id) end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    tool_ids != [] and Enum.all?(tool_ids, &MapSet.member?(message_tool_ids, &1))
  end

  defp assistant_message_with_tool_calls?(_message, _tool_ids), do: false

  defp tool_message?(%{"role" => "tool"}), do: true
  defp tool_message?(_message), do: false

  defp sanitize_history_entry(m) do
    entry = %{
      "role" => Map.get(m, "role"),
      "content" => sanitize_message_content(Map.get(m, "content", "") || "")
    }

    entry =
      if tool_calls = Map.get(m, "tool_calls") do
        Map.put(entry, "tool_calls", tool_calls)
      else
        entry
      end

    entry =
      if tcid = Map.get(m, "tool_call_id") do
        entry
        |> Map.put("tool_call_id", tcid)
        |> then(fn e ->
          if name = Map.get(m, "name"), do: Map.put(e, "name", name), else: e
        end)
      else
        entry
      end

    entry
  end

  @doc """
  Clear all messages and reset consolidation state.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = session) do
    %{session | messages: [], last_consolidated: 0, updated_at: DateTime.utc_now()}
  end

  @doc """
  Save session to disk as JSONL.
  """
  @spec save(t(), keyword()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = session, opts \\ []) do
    dir = session_dir(session.key, opts)
    File.mkdir_p!(dir)

    path = messages_path(session.key, opts)

    lines =
      [
        %{
          "_type" => "metadata",
          "key" => session.key,
          "created_at" => session.created_at |> DateTime.to_iso8601(),
          "updated_at" => session.updated_at |> DateTime.to_iso8601(),
          "metadata" => session.metadata,
          "last_consolidated" => session.last_consolidated
        }
        | session.messages
      ]
      |> Enum.map(&Jason.encode!/1)

    File.write(path, Enum.join(lines, "\n"))
  end

  @doc """
  Load session from disk.
  """
  @spec load(String.t(), keyword()) :: t() | nil
  def load(key, opts \\ []) do
    path = messages_path(key, opts)

    if File.exists?(path) do
      load_from_path(path, key)
    else
      nil
    end
  end

  defp load_from_path(path, key) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n", trim: true)

        {metadata, messages} =
          Enum.split_with(lines, fn line ->
            case Jason.decode(line) do
              {:ok, %{"_type" => "metadata"}} -> true
              _ -> false
            end
          end)

        meta =
          case metadata do
            [line | _] ->
              case Jason.decode(line) do
                {:ok, m} -> m
                _ -> %{}
              end

            _ ->
              %{}
          end

        parsed_messages =
          messages
          |> Enum.map(&Jason.decode/1)
          |> Enum.filter(fn
            {:ok, _} -> true
            _ -> false
          end)
          |> Enum.map(fn {:ok, m} -> m end)

        %__MODULE__{
          key: key,
          messages: parsed_messages,
          created_at: parse_datetime(Map.get(meta, "created_at")),
          updated_at: parse_datetime(Map.get(meta, "updated_at")),
          metadata: Map.get(meta, "metadata", %{}),
          last_consolidated: Map.get(meta, "last_consolidated", 0)
        }

      _ ->
        nil
    end
  end

  defp safe_filename(key) do
    key |> String.replace(":", "_") |> String.replace(~r/[^\w-]/, "_")
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp sanitize_message_content(nil), do: ""

  defp sanitize_message_content(content) when is_binary(content) do
    if String.valid?(content) do
      content
    else
      preview =
        content
        |> binary_part(0, min(byte_size(content), 256))
        |> Base.encode64()

      "Binary output (#{byte_size(content)} bytes, base64 preview): #{preview}"
    end
  end

  defp sanitize_message_content(content), do: inspect(content, printable_limit: 500, limit: 50)
end
