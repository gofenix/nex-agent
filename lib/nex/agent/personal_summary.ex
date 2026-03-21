defmodule Nex.Agent.PersonalSummary do
  @moduledoc false

  alias Nex.Agent.{Executor, Knowledge, Tasks}

  @spec build(String.t(), keyword()) :: String.t()
  def build(scope, opts \\ []) when scope in ["daily", "weekly", "all"] do
    workspace = Keyword.get(opts, :workspace)
    tasks = Keyword.get(opts, :tasks, Tasks.list(workspace_opts(workspace)))
    captures = Knowledge.list(workspace_opts(workspace) ++ [limit: capture_limit(scope)])
    runs = Executor.recent_runs(workspace_opts(workspace) ++ [limit: capture_limit(scope)])

    open_tasks = Enum.count(tasks, &(&1["status"] in ["open", "snoozed"]))
    completed_tasks = Enum.count(tasks, &(&1["status"] == "completed"))

    upcoming =
      tasks
      |> Enum.filter(&(&1["status"] in ["open", "snoozed"]))
      |> Enum.filter(&(is_binary(&1["due_at"]) or is_binary(&1["follow_up_at"])))
      |> Enum.take(5)

    """
    #{header(scope)}
    Open tasks: #{open_tasks}
    Completed tasks: #{completed_tasks}
    Knowledge captures: #{length(captures)}
    Executor runs: #{length(runs)}

    Upcoming:
    #{format_upcoming(upcoming)}

    Recent knowledge:
    #{format_captures(captures)}

    Recent execution:
    #{format_runs(runs)}
    """
    |> String.trim()
  end

  @spec ensure_default_jobs(String.t(), String.t(), keyword()) :: :ok
  def ensure_default_jobs(channel, chat_id, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) do
    workspace_opts = workspace_opts(Keyword.get(opts, :workspace))

    if not is_nil(Process.whereis(Nex.Agent.Cron)) and personal_chat?(channel, chat_id, opts) do
      ensure_job(
        "personal:daily-summary:#{channel}:#{chat_id}",
        "0 21 * * *",
        daily_message(),
        channel,
        chat_id,
        workspace_opts
      )

      ensure_job(
        "personal:weekly-summary:#{channel}:#{chat_id}",
        "0 9 * * 1",
        weekly_message(),
        channel,
        chat_id,
        workspace_opts
      )
    end

    :ok
  end

  defp ensure_job(name, cron_expr, message, channel, chat_id, workspace_opts) do
    _ =
      Nex.Agent.Cron.upsert_job(
        %{
          name: name,
          message: message,
          channel: channel,
          chat_id: chat_id,
          schedule: %{type: :cron, expr: cron_expr},
          delete_after_run: false
        },
        workspace_opts
      )
  end

  defp daily_message do
    """
    Create a daily personal summary. Use the `task` tool with action=`summary` and scope=`daily`, then send the user a concise end-of-day update only if there is something useful to report.
    """
    |> String.trim()
  end

  defp weekly_message do
    """
    Create a weekly personal summary. Use the `task` tool with action=`summary` and scope=`weekly`, then send the user a concise weekly review with priorities and follow-ups.
    """
    |> String.trim()
  end

  defp header("daily"), do: "Daily Personal Summary"
  defp header("weekly"), do: "Weekly Personal Summary"
  defp header("all"), do: "Personal Summary"

  defp capture_limit("daily"), do: 10
  defp capture_limit("weekly"), do: 20
  defp capture_limit("all"), do: 20

  defp format_upcoming([]), do: "- none"

  defp format_upcoming(tasks) do
    Enum.map_join(tasks, "\n", fn task ->
      timestamp = task["due_at"] || task["follow_up_at"] || "unscheduled"
      "- #{task["title"]} @ #{timestamp}"
    end)
  end

  defp format_captures([]), do: "- none"

  defp format_captures(captures) do
    Enum.map_join(captures, "\n", fn capture ->
      "- [#{capture["source"]}] #{capture["title"]}"
    end)
  end

  defp format_runs([]), do: "- none"

  defp format_runs(runs) do
    Enum.map_join(runs, "\n", fn run ->
      status = run["status"] || "unknown"
      executor = run["executor"] || "executor"
      task = run["summary"] || run["task"] || "(task omitted)"
      "- #{executor} #{status}: #{String.slice(task, 0, 80)}"
    end)
  end

  defp workspace_opts(nil), do: []
  defp workspace_opts(workspace), do: [workspace: workspace]

  defp personal_chat?("feishu", _chat_id, opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    chat_type = Map.get(metadata, "chat_type") || Map.get(metadata, :chat_type)
    to_string(chat_type) == "p2p"
  end

  defp personal_chat?("telegram", chat_id, opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    user_id = Map.get(metadata, "user_id") || Map.get(metadata, :user_id)
    is_binary(chat_id) and is_binary(user_id) and chat_id == user_id
  end

  defp personal_chat?("discord", _chat_id, opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    is_nil(Map.get(metadata, "guild_id") || Map.get(metadata, :guild_id))
  end

  defp personal_chat?("dingtalk", _chat_id, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    conversation_type =
      Map.get(metadata, "conversation_type") || Map.get(metadata, :conversation_type)

    to_string(conversation_type) in ["1", "singleChat"]
  end

  defp personal_chat?(_channel, _chat_id, _opts), do: false
end
