defmodule Nex.Agent.Tool.MemoryStatus do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.{Memory, MemoryUpdater, Session, SessionManager}

  def name, do: "memory_status"

  def description do
    """
    Inspect memory refresh status for the current session and workspace.

    Use this when the user wants to check memory status only:
    - "check memory status" / "was memory refreshed?"
    - "检查记忆状态" / "刚才更新记忆了吗"

    This does not run a refresh. Use `memory_consolidate` to trigger an immediate refresh now.
    Use `memory_rebuild` only for a full rebuild of MEMORY.md.
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
            description: "Optional session key to inspect. Defaults to current session."
          }
        }
      }
    }
  end

  def execute(args, ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")

    session_key =
      Map.get(args, "session_key") ||
        Map.get(ctx, :session_key) ||
        Map.get(ctx, "session_key") ||
        derive_session_key(ctx)

    session = load_session(session_key, workspace)
    memory_content = Memory.read_long_term(workspace: workspace)
    total_messages = if session, do: length(session.messages), else: 0
    last_consolidated = if session, do: session.last_consolidated, else: 0
    unreviewed = max(total_messages - last_consolidated, 0)
    updater = MemoryUpdater.status(session_key || "", workspace: workspace)

    {:ok,
     %{
       "session_key" => session_key,
       "status" => status_for(session_key, updater["status"], unreviewed),
       "reason" => reason_for(session_key, updater["status"], unreviewed),
       "session" => %{
         "exists" => not is_nil(session),
         "total_messages" => total_messages,
         "last_reviewed_message_count" => last_consolidated,
         "unreviewed_messages" => unreviewed
       },
       "memory_files" => %{
         "memory_has_user_content" => has_meaningful_memory_content?(memory_content),
         "memory_bytes" => byte_size(memory_content)
       },
       "refresh" => %{
         "job_status" => updater["status"],
         "queued_jobs_for_session" => updater["queued"]
       }
     }}
  end

  defp load_session(nil, _workspace), do: nil
  defp load_session("", _workspace), do: nil

  defp load_session(session_key, workspace) do
    session_opts = workspace_opts(workspace)

    if Process.whereis(SessionManager) do
      SessionManager.get(session_key, session_opts) || Session.load(session_key, session_opts)
    else
      Session.load(session_key, session_opts)
    end
  end

  defp workspace_opts(nil), do: []
  defp workspace_opts(workspace), do: [workspace: workspace]

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

  defp has_meaningful_memory_content?(content) do
    content
    |> strip_template_lines()
    |> Enum.any?(&(String.trim(&1) != ""))
  end

  defp strip_template_lines(content) do
    content
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)

      trimmed == "" or
        String.starts_with?(trimmed, "#") or
        String.starts_with?(trimmed, "##") or
        String.starts_with?(trimmed, "---") or
        String.starts_with?(trimmed, "*This file is automatically updated") or
        String.starts_with?(trimmed, "(Stable facts") or
        String.starts_with?(trimmed, "(Important project-specific") or
        String.starts_with?(trimmed, "(Information about ongoing projects)") or
        String.starts_with?(trimmed, "(Reusable lessons learned")
    end)
  end

  defp status_for(nil, _job_status, _unreviewed), do: "unknown"
  defp status_for("", _job_status, _unreviewed), do: "unknown"
  defp status_for(_session_key, "running", _unreviewed), do: "running"
  defp status_for(_session_key, "queued", _unreviewed), do: "queued"
  defp status_for(_session_key, _job_status, unreviewed) when unreviewed > 0, do: "pending"
  defp status_for(_session_key, _job_status, _unreviewed), do: "idle"

  defp reason_for(nil, _job_status, _unreviewed), do: "missing_session_key"
  defp reason_for("", _job_status, _unreviewed), do: "missing_session_key"
  defp reason_for(_session_key, "running", _unreviewed), do: "memory_refresh_running"
  defp reason_for(_session_key, "queued", _unreviewed), do: "memory_refresh_queued"

  defp reason_for(_session_key, _job_status, unreviewed) when unreviewed > 0,
    do: "unreviewed_messages"

  defp reason_for(_session_key, _job_status, _unreviewed), do: "up_to_date"
end
