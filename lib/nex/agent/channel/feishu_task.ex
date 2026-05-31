defmodule Nex.Agent.Channel.FeishuTask do
  @moduledoc false

  require Logger

  @dedup_ttl_seconds 300
  @dedup_dir "tasks"

  def normalize(%{"header" => %{"event_type" => "task.task.created_v1"}} = payload) do
    task = payload["event"] || %{}
    task_id = task["task_id"]
    operator_id = get_in(payload, ["header", "operator_user_id"])
    creator_id = task["creator_id"] || operator_id

    if is_nil(task_id) or task_id == "" do
      Logger.warning("[FeishuTask] created event missing task_id")
      :ignore
    else
      {:ok,
       %{
         channel: "feishu",
         chat_id: creator_id,
         content: "/run_feishu_task #{task_id}",
         metadata: %{
           _from_feishu_task: true,
           task_id: task_id,
           task_title: task["title"] || "",
           task_description: task["description"] || "",
           task_action: "created",
           creator_id: creator_id,
           operator_user_id: operator_id
         }
       }}
    end
  end

  def normalize(%{"header" => %{"event_type" => "task.task.updated_v1"}} = payload) do
    task = payload["event"] || %{}
    task_id = task["task_id"]
    old_status = get_in(task, ["changes", "status", "old"]) || ""
    new_status = get_in(task, ["changes", "status", "new"]) || ""
    operator_id = get_in(payload, ["header", "operator_user_id"])
    creator_id = task["creator_id"] || operator_id

    if task_id && old_status == "completed" && new_status == "in_progress" &&
         operator_id == creator_id do
      {:ok,
       %{
         channel: "feishu",
         chat_id: creator_id,
         content: "/rerun_feishu_task #{task_id}",
         metadata: %{
           _from_feishu_task: true,
           task_id: task_id,
           task_title: task["title"] || "",
           task_description: task["description"] || "",
           task_action: "rerun",
           creator_id: creator_id,
           operator_user_id: operator_id
         }
       }}
    else
      :ignore
    end
  end

  def normalize(%{"header" => %{"event_type" => "task.task.comment.created_v1"}} = payload) do
    task = payload["event"] || %{}
    task_id = task["task_id"]
    comment = get_in(task, ["comment", "content"]) || ""
    operator_id = get_in(payload, ["header", "operator_user_id"])
    creator_id = task["creator_id"] || operator_id

    if task_id && comment =~ "/rerun" && operator_id == creator_id do
      {:ok,
       %{
         channel: "feishu",
         chat_id: creator_id,
         content: "/rerun_feishu_task #{task_id}",
         metadata: %{
           _from_feishu_task: true,
           task_id: task_id,
           task_title: task["title"] || "",
           task_description: task["description"] || "",
           task_action: "rerun",
           creator_id: creator_id,
           operator_user_id: operator_id
         }
       }}
    else
      :ignore
    end
  end

  def normalize(_payload), do: :not_matched

  def dup?(bot_open_id, operator_id, task_id, action, workspace) do
    cond do
      operator_id == bot_open_id ->
        true

      true ->
        dedup_dup?(task_id, action, workspace)
    end
  end

  def record_dedup(task_id, action, workspace) do
    entries = read_dedup(workspace)
    now = System.system_time(:second)
    expires_at = now + @dedup_ttl_seconds

    pruned =
      Enum.reject(entries, fn %{"expires_at" => exp} -> now >= exp end) ++
        [%{"task_id" => task_id, "action" => action, "expires_at" => expires_at}]

    File.mkdir_p!(Path.join(workspace, @dedup_dir))
    File.write!(dedup_path(workspace), Jason.encode!(pruned))
  end

  defp dedup_dup?(task_id, action, workspace) do
    entries = read_dedup(workspace)
    now = System.system_time(:second)

    Enum.any?(entries, fn %{"task_id" => tid, "action" => act, "expires_at" => exp} ->
      tid == task_id and act == action and now < exp
    end)
  end

  defp read_dedup(workspace) do
    path = dedup_path(workspace)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, entries} when is_list(entries) -> entries
          _ -> []
        end

      _ ->
        []
    end
  end

  defp dedup_path(workspace), do: Path.join([workspace, @dedup_dir, "dedup.json"])
end
