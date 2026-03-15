defmodule Nex.Agent.Tool.MemoryRebuild do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.{Memory, Session, SessionManager}

  def name, do: "memory_rebuild"

  def description do
    """
    Run a full memory consolidation pass for the current session.

    This reprocesses the entire session history into MEMORY.md and HISTORY.md instead of waiting
    for the normal incremental threshold. Use this when long-term memory is stale or clearly incomplete.
    """
  end

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          session_key: %{
            type: "string",
            description: "Optional session key to rebuild. Defaults to the current session."
          },
          batch_messages: %{
            type: "integer",
            description:
              "How many messages to process per consolidation batch during a full rebuild. Lower this if the model hits token limits."
          }
        }
      }
    }
  end

  def execute(args, ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")
    provider = Map.get(ctx, :provider) || Map.get(ctx, "provider") || :anthropic
    model = Map.get(ctx, :model) || Map.get(ctx, "model")
    api_key = Map.get(ctx, :api_key) || Map.get(ctx, "api_key")
    base_url = Map.get(ctx, :base_url) || Map.get(ctx, "base_url")
    llm_call_fun = Map.get(ctx, :llm_call_fun) || Map.get(ctx, "llm_call_fun")

    batch_messages =
      Map.get(args, "batch_messages") ||
        Map.get(ctx, :batch_messages) ||
        Map.get(ctx, "batch_messages")
        |> normalize_batch_size()

    session_key =
      Map.get(args, "session_key") ||
        Map.get(ctx, :session_key) ||
        Map.get(ctx, "session_key") ||
        derive_session_key(ctx)

    with {:ok, session_key} <- validate_session_key(session_key),
         {:ok, session} <- fetch_session(session_key),
         {:ok, updated_session} <-
           rebuild_session(
             session,
             provider,
             model,
             api_key,
             base_url,
             workspace,
             llm_call_fun,
             batch_messages
           ) do
      persist_session(updated_session)

      {:ok,
       %{
         "session_key" => session_key,
         "processed_messages" => length(session.messages),
         "batches_processed" => batches_processed(length(session.messages), batch_messages),
         "batch_messages" => batch_messages,
         "last_consolidated_before" => session.last_consolidated,
         "last_consolidated_after" => updated_session.last_consolidated,
         "memory_bytes" => byte_size(Memory.read_long_term(workspace: workspace)),
         "history_bytes" => history_bytes(workspace)
       }}
    end
  end

  defp rebuild_session(
         %Session{} = session,
         provider,
         model,
         api_key,
         base_url,
         workspace,
         llm_call_fun,
         batch_size
       ) do
    model = model || "claude-sonnet-4-20250514"

    session.messages
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, 0}, fn {batch, idx}, {:ok, _processed} ->
      batch_session = %Session{session | messages: batch, last_consolidated: 0}

      opts =
        [
          api_key: api_key,
          base_url: base_url,
          archive_all: true,
          workspace: workspace
        ]
        |> maybe_put(:llm_call_fun, llm_call_fun)

      case Memory.consolidate(batch_session, provider, model, opts) do
        {:ok, _updated_batch_session} ->
          processed = min(idx * batch_size, length(session.messages))
          {:cont, {:ok, processed}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _processed} ->
        {:ok, %Session{session | last_consolidated: length(session.messages)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_session(session_key) do
    case SessionManager.get(session_key) || Session.load(session_key) do
      nil -> {:error, "Session not found: #{session_key}"}
      session -> {:ok, session}
    end
  end

  defp persist_session(session) do
    :ok = Session.save(session)

    if Process.whereis(SessionManager) do
      SessionManager.invalidate(session.key)
    end
  end

  defp validate_session_key(nil), do: {:error, "session_key is required"}
  defp validate_session_key(""), do: {:error, "session_key is required"}
  defp validate_session_key(session_key), do: {:ok, session_key}

  defp history_bytes(workspace) do
    path = Path.join(memory_dir(workspace), "HISTORY.md")
    if File.exists?(path), do: File.stat!(path).size, else: 0
  end

  defp memory_dir(nil), do: Path.join(Memory.workspace_path(), "memory")
  defp memory_dir(workspace), do: Path.join(workspace, "memory")

  defp derive_session_key(ctx) do
    channel = Map.get(ctx, :channel) || Map.get(ctx, "channel")
    chat_id = Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id")

    if present?(channel) and present?(chat_id) do
      "#{channel}:#{chat_id}"
    else
      nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp normalize_batch_size(value) when is_integer(value) and value > 0, do: min(value, 500)
  defp normalize_batch_size(_), do: 120

  defp batches_processed(total_messages, batch_size) when total_messages > 0 do
    ceil(total_messages / batch_size)
  end

  defp batches_processed(_total_messages, _batch_size), do: 0

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
