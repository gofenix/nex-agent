defmodule Nex.Agent.Tool.MemoryConsolidate do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.{Memory, Session, SessionManager}

  @default_model "claude-sonnet-4-20250514"
  @memory_window 50

  def name, do: "memory_consolidate"

  def description do
    """
    Immediately run normal memory consolidation for the current session.

    Use this when the user explicitly asks to trigger or run memory consolidation now:
    - "trigger memory consolidation" / "run memory consolidation"
    - "触发记忆整理" / "现在整理记忆"

    This is not a full rebuild. Use `memory_status` to only check status.
    Use `memory_rebuild` only for a full rebuild of MEMORY.md and HISTORY.md from the full session history.
    """
  end

  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          session_key: %{
            type: "string",
            description: "Optional session key to consolidate. Defaults to the current session."
          }
        }
      }
    }
  end

  def execute(args, ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")
    provider = Map.get(ctx, :provider) || Map.get(ctx, "provider") || :anthropic
    model = Map.get(ctx, :model) || Map.get(ctx, "model") || @default_model
    api_key = Map.get(ctx, :api_key) || Map.get(ctx, "api_key")
    base_url = Map.get(ctx, :base_url) || Map.get(ctx, "base_url")
    llm_call_fun = Map.get(ctx, :llm_call_fun) || Map.get(ctx, "llm_call_fun")

    req_llm_generate_text_fun =
      Map.get(ctx, :req_llm_generate_text_fun) || Map.get(ctx, "req_llm_generate_text_fun")

    session_key =
      Map.get(args, "session_key") ||
        Map.get(ctx, :session_key) ||
        Map.get(ctx, "session_key") ||
        derive_session_key(ctx)

    with {:ok, session_key} <- validate_session_key(session_key) do
      session_opts = workspace_opts(workspace)

      case SessionManager.start_explicit_consolidation(session_key, session_opts) do
        {:ok, session, _unconsolidated} ->
          case consolidation_reason(session, @memory_window) do
            nil ->
              opts =
                [
                  api_key: api_key,
                  base_url: base_url,
                  memory_window: @memory_window,
                  workspace: workspace
                ]
                |> maybe_put(:llm_call_fun, llm_call_fun)
                |> maybe_put(:req_llm_generate_text_fun, req_llm_generate_text_fun)

              result =
                try do
                  Memory.consolidate(session, provider, model, opts)
                rescue
                  error ->
                    {:error, {:exception, Exception.message(error)}}
                catch
                  kind, reason ->
                    {:error, {kind, reason}}
                end

              case result do
                {:ok, updated_session} ->
                  SessionManager.finish_consolidation(updated_session, session_opts)

                  status =
                    if updated_session.last_consolidated > session.last_consolidated,
                      do: "consolidated",
                      else: "noop"

                  reason =
                    if status == "consolidated",
                      do: "ok",
                      else: consolidation_reason(updated_session, @memory_window) || "ok"

                  {:ok,
                   result_payload(
                     session_key,
                     status,
                     reason,
                     session,
                     updated_session,
                     workspace
                   )}

                {:error, reason} ->
                  SessionManager.cancel_consolidation(session_key, session_opts)
                  {:error, reason}
              end

            reason ->
              SessionManager.cancel_consolidation(session_key, session_opts)
              {:ok, result_payload(session_key, "noop", reason, session, session, workspace)}
          end

        :already_running ->
          session = fetch_session(session_key, workspace)
          session = session || Session.new(session_key)

          {:ok,
           result_payload(
             session_key,
             "already_running",
             "consolidation_in_progress",
             session,
             session,
             workspace
           )}
      end
    end
  end

  defp consolidation_reason(%Session{} = session, memory_window) do
    keep_count = div(memory_window, 2)
    unconsolidated = max(length(session.messages) - session.last_consolidated, 0)

    cond do
      unconsolidated <= 0 -> "no_unconsolidated_messages"
      length(session.messages) <= keep_count -> "below_keep_window"
      true -> nil
    end
  end

  defp result_payload(session_key, status, reason, before_session, after_session, workspace) do
    %{
      "session_key" => session_key,
      "status" => status,
      "reason" => reason,
      "last_consolidated_before" => before_session.last_consolidated,
      "last_consolidated_after" => after_session.last_consolidated,
      "memory_bytes" => byte_size(Memory.read_long_term(workspace: workspace)),
      "history_bytes" => history_bytes(workspace)
    }
  end

  defp fetch_session(session_key, workspace) do
    session_opts = workspace_opts(workspace)

    if Process.whereis(SessionManager) do
      SessionManager.get(session_key, session_opts) || Session.load(session_key, session_opts)
    else
      Session.load(session_key, session_opts)
    end
  end

  defp history_bytes(workspace) do
    path = Path.join(memory_dir(workspace), "HISTORY.md")
    if File.exists?(path), do: File.stat!(path).size, else: 0
  end

  defp memory_dir(nil), do: Path.join(Memory.workspace_path(), "memory")
  defp memory_dir(workspace), do: Path.join(workspace, "memory")

  defp validate_session_key(nil), do: {:error, "session_key is required"}
  defp validate_session_key(""), do: {:error, "session_key is required"}
  defp validate_session_key(session_key), do: {:ok, session_key}

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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp workspace_opts(nil), do: []
  defp workspace_opts(workspace), do: [workspace: workspace]
end
