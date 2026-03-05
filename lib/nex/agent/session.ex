defmodule Nex.Agent.Session do
  @moduledoc """
  Simple session management - stores messages as list, persists to JSONL.
  Mirrors nanobot's session/manager.py Session class.
  """

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

  @sessions_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/sessions")

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
          "content" => content,
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
  def get_history(%__MODULE__{} = session, max_messages \\ 50) do
    unconsolidated = Enum.drop(session.messages, session.last_consolidated)
    sliced = Enum.take(unconsolidated, -max_messages)

    aligned =
      case Enum.find_index(sliced, fn m -> Map.get(m, "role") == "user" end) do
        nil -> sliced
        idx -> Enum.drop(sliced, idx)
      end

    Enum.map(aligned, fn m ->
      entry = %{
        "role" => Map.get(m, "role"),
        "content" => Map.get(m, "content", "") || ""
      }

      entry =
        if tool_calls = Map.get(m, "tool_calls") do
          Map.put(entry, "tool_calls", tool_calls)
        else
          entry
        end

      entry =
        if tool_call_id = Map.get(m, "tool_call_id") do
          Map.put(entry, "tool_call_id", tool_call_id)
        else
          entry
        end

      entry =
        if name = Map.get(m, "name") do
          Map.put(entry, "name", name)
        else
          entry
        end

      entry =
        if rc = Map.get(m, "reasoning_content") do
          Map.put(entry, "reasoning_content", rc)
        else
          entry
        end

      entry
    end)
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
  @spec save(t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = session) do
    dir = Path.join([@sessions_dir, safe_filename(session.key)])
    File.mkdir_p!(dir)

    path = Path.join(dir, "messages.jsonl")

    lines =
      [
        %{
          "_type" => "metadata",
          "key" => session.key,
          "created_at" => session.created_at |> DateTime.to_iso8601(),
          "updated_at" => session.updated_at |> DateTime.to_iso8601(),
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
  @spec load(String.t()) :: t() | nil
  def load(key) do
    dir = Path.join([@sessions_dir, safe_filename(key)])
    path = Path.join(dir, "messages.jsonl")

    unless File.exists?(path) do
      nil
    else
      load_from_path(path, key)
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
          metadata: %{},
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
end
