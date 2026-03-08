defmodule Nex.Agent.Session do
  @moduledoc """
  Simple session management - stores messages as list, persists to JSONL.
  Mirrors nanobot's session/manager.py Session class.
  """

  require Logger

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

  @sessions_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace/sessions")

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

    # Align to start of a complete turn (user message).
    # Drop leading assistant/tool messages that are mid-turn fragments.
    aligned =
      case Enum.find_index(sliced, fn m -> Map.get(m, "role") == "user" end) do
        nil ->
          # No user message — check if we start with a valid assistant turn
          case sliced do
            [%{"role" => "assistant"} | _] -> sliced
            _ -> []
          end
        idx ->
          Enum.drop(sliced, idx)
      end

    aligned
    |> Enum.map(&sanitize_history_entry/1)
    |> sanitize_tool_pairs()
  end

  defp sanitize_history_entry(m) do
    entry = %{
      "role" => Map.get(m, "role"),
      "content" => Map.get(m, "content", "") || ""
    }

    entry =
      if tool_calls = Map.get(m, "tool_calls") do
        sanitized =
          Enum.map(tool_calls, fn tc ->
            if Map.get(tc, "id"), do: tc, else: Map.put(tc, "id", generate_fallback_id())
          end)

        Map.put(entry, "tool_calls", sanitized)
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
        if Map.get(m, "role") == "tool" do
          Map.put(entry, "tool_call_id", nil)
        else
          entry
        end
      end

    if rc = Map.get(m, "reasoning_content") do
      Map.put(entry, "reasoning_content", rc)
    else
      entry
    end
  end

  # Ensure every tool_use has a matching tool_result in the same turn.
  # Drop orphaned assistant tool_calls and orphaned tool results.
  defp sanitize_tool_pairs(messages) do
    # Process sequentially: track pending tool_call_ids per assistant turn
    {result, pending} =
      Enum.reduce(messages, {[], MapSet.new()}, fn m, {acc, pending} ->
        cond do
          m["role"] == "assistant" && is_list(m["tool_calls"]) && m["tool_calls"] != [] ->
            # New assistant turn with tool_calls.
            # First, strip any still-pending tool_calls from previous assistant
            # (they had no matching results). Then set new pending.
            acc = strip_pending_tool_calls(acc, pending)
            tc_ids = m["tool_calls"] |> Enum.map(&(&1["id"])) |> MapSet.new()
            {acc ++ [m], tc_ids}

          m["role"] == "tool" ->
            tcid = m["tool_call_id"]

            if tcid && MapSet.member?(pending, tcid) do
              {acc ++ [m], MapSet.delete(pending, tcid)}
            else
              # Orphaned tool result (nil ID or no matching use) — drop it
              {acc, pending}
            end

          m["role"] == "user" || m["role"] == "assistant" ->
            # New turn. If there are still pending tool_call_ids,
            # strip them from the last assistant message.
            acc = strip_pending_tool_calls(acc, pending)
            {acc ++ [m], MapSet.new()}

          true ->
            {acc ++ [m], pending}
        end
      end)

    # Strip any remaining orphaned tool_calls at the end of history
    strip_pending_tool_calls(result, pending)
  end

  # Remove unmatched tool_call entries from the last assistant message
  defp strip_pending_tool_calls(messages, pending) do
    if MapSet.size(pending) == 0 do
      messages
    else
      Logger.warning("[Session] Stripping #{MapSet.size(pending)} orphaned tool_call(s): #{inspect(MapSet.to_list(pending))}")

      # Find the last assistant message with tool_calls and strip orphaned ones
      {rev_before, rev_after} =
        messages
        |> Enum.reverse()
        |> Enum.split_while(fn m ->
          not (m["role"] == "assistant" && is_list(m["tool_calls"]))
        end)

      case rev_after do
        [assistant | rest] ->
          kept = Enum.reject(assistant["tool_calls"], &MapSet.member?(pending, &1["id"]))

          updated =
            if kept == [] do
              Map.delete(assistant, "tool_calls")
            else
              %{assistant | "tool_calls" => kept}
            end

          Enum.reverse(rest) ++ [updated] ++ Enum.reverse(rev_before)

        [] ->
          messages
      end
    end
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

  defp generate_fallback_id do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
