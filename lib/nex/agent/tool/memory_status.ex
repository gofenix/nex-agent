defmodule Nex.Agent.Tool.MemoryStatus do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.{Memory, Session, SessionManager}

  @memory_window 50
  @memory_nudge_interval 6

  def name, do: "memory_status"

  def description do
    "Inspect memory consolidation status for the current session and workspace."
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
    history_content = read_history(workspace)
    runtime_evolution = session_metadata(session, "runtime_evolution") || %{}
    total_messages = if session, do: length(session.messages), else: 0
    last_consolidated = if session, do: session.last_consolidated, else: 0
    unconsolidated = max(total_messages - last_consolidated, 0)
    in_progress = session_metadata(session, "consolidation_in_progress") == true
    started_at = session_metadata(session, "consolidation_started_at")
    stale = in_progress and stale_timestamp?(started_at)

    {:ok,
     %{
       "session_key" => session_key,
       "status" => status_for(session_key, unconsolidated, in_progress, stale),
       "reason" => reason_for(session_key, unconsolidated, in_progress, stale),
       "thresholds" => %{
         "consolidation_min_unconsolidated_messages" => @memory_window,
         "memory_nudge_interval_turns" => @memory_nudge_interval
       },
       "session" => %{
         "exists" => not is_nil(session),
         "total_messages" => total_messages,
         "last_consolidated" => last_consolidated,
         "unconsolidated_messages" => unconsolidated,
         "consolidation_in_progress" => in_progress,
         "consolidation_started_at" => started_at,
         "consolidation_stale" => stale
       },
       "memory_files" => %{
         "memory_has_user_content" => has_meaningful_memory_content?(memory_content),
         "history_has_entries" => has_history_entries?(history_content),
         "memory_bytes" => byte_size(memory_content),
         "history_bytes" => byte_size(history_content)
       },
       "runtime_evolution" => %{
         "turns_since_memory_write" => runtime_evolution["turns_since_memory_write"] || 0,
         "next_memory_nudge_due_in_turns" =>
           turns_until_next_nudge(runtime_evolution["turns_since_memory_write"] || 0)
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

  defp read_history(workspace) do
    history_file = Path.join(memory_dir(workspace), "HISTORY.md")
    if File.exists?(history_file), do: File.read!(history_file), else: ""
  end

  defp memory_dir(nil), do: Path.join(Memory.workspace_path(), "memory")
  defp memory_dir(workspace), do: Path.join(workspace, "memory")

  defp workspace_opts(nil), do: []
  defp workspace_opts(workspace), do: [workspace: workspace]

  defp session_metadata(nil, _key), do: nil
  defp session_metadata(session, key), do: Map.get(session.metadata || %{}, key)

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

  defp stale_timestamp?(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, started_at, _offset} -> DateTime.diff(DateTime.utc_now(), started_at, :second) >= 900
      _ -> true
    end
  end

  defp stale_timestamp?(_), do: true

  defp has_meaningful_memory_content?(content) do
    content
    |> strip_template_lines()
    |> Enum.any?(&(String.trim(&1) != ""))
  end

  defp has_history_entries?(content) do
    content
    |> String.split("\n")
    |> Enum.any?(&String.match?(&1, ~r/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\]/))
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

  defp turns_until_next_nudge(turns_since_memory_write)
       when is_integer(turns_since_memory_write) do
    remainder = rem(turns_since_memory_write, @memory_nudge_interval)
    if remainder == 0, do: 0, else: @memory_nudge_interval - remainder
  end

  defp turns_until_next_nudge(_), do: @memory_nudge_interval

  defp status_for(nil, _unconsolidated, _in_progress, _stale), do: "unknown"
  defp status_for("", _unconsolidated, _in_progress, _stale), do: "unknown"
  defp status_for(_session_key, _unconsolidated, true, true), do: "blocked"
  defp status_for(_session_key, _unconsolidated, true, false), do: "running"

  defp status_for(_session_key, unconsolidated, false, _stale)
       when unconsolidated >= @memory_window,
       do: "ready"

  defp status_for(_session_key, _unconsolidated, false, _stale), do: "idle"

  defp reason_for(nil, _unconsolidated, _in_progress, _stale), do: "missing_session_key"
  defp reason_for("", _unconsolidated, _in_progress, _stale), do: "missing_session_key"
  defp reason_for(_session_key, _unconsolidated, true, true), do: "stale_consolidation_flag"
  defp reason_for(_session_key, _unconsolidated, true, false), do: "consolidation_in_progress"

  defp reason_for(_session_key, unconsolidated, false, _stale)
       when unconsolidated >= @memory_window,
       do: "threshold_reached"

  defp reason_for(_session_key, _unconsolidated, false, _stale), do: "below_threshold"
end
