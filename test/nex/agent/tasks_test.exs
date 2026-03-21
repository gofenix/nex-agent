defmodule Nex.Agent.TasksTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tasks

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-tasks-#{System.unique_integer([:positive])}")

    previous_workspace = Application.get_env(:nex_agent, :workspace_path)
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Nex.Agent.Onboarding.ensure_initialized()

    on_exit(fn ->
      cleanup_task_jobs("task_", workspace)

      if previous_workspace do
        Application.put_env(:nex_agent, :workspace_path, previous_workspace)
      else
        Application.delete_env(:nex_agent, :workspace_path)
      end

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "add, update, complete, and summarize personal tasks", %{workspace: workspace} do
    assert {:ok, task} =
             Tasks.add(
               %{
                 "title" => "Review personal roadmap",
                 "due_at" => "2026-03-21T09:30:00Z",
                 "project" => "nex-agent"
               },
               workspace: workspace,
               channel: "feishu",
               chat_id: "chat-123"
             )

    assert File.exists?(Tasks.task_file(workspace: workspace))
    assert task["channel"] == "feishu"
    assert task["chat_id"] == "chat-123"
    task_id = task["id"]
    assert Enum.any?(Tasks.list(workspace: workspace), &(&1["id"] == task_id))

    assert {:ok, updated} =
             Tasks.update(
               task["id"],
               %{
                 "summary" => "Need a compact P0/P1 split",
                 "follow_up_at" => "2026-03-22T08:00:00Z"
               },
               workspace: workspace,
               channel: "feishu",
               chat_id: "chat-123"
             )

    assert updated["summary"] == "Need a compact P0/P1 split"
    assert updated["follow_up_at"] == "2026-03-22T08:00:00Z"

    if Process.whereis(Nex.Agent.Cron) do
      jobs = Nex.Agent.Cron.list_jobs(workspace: workspace)
      assert Enum.any?(jobs, &(&1.name == "task_due:#{task["id"]}" and &1.channel == "feishu"))

      assert Enum.any?(
               jobs,
               &(&1.name == "task_follow_up:#{task["id"]}" and &1.chat_id == "chat-123")
             )
    end

    assert {:ok, completed} = Tasks.complete(task["id"], "Shipped the plan", workspace: workspace)
    assert completed["status"] == "completed"
    assert completed["due_at"] == nil
    assert completed["follow_up_at"] == nil

    if Process.whereis(Nex.Agent.Cron) do
      refute Enum.any?(
               Nex.Agent.Cron.list_jobs(workspace: workspace),
               &String.ends_with?(&1.name, task["id"])
             )
    end

    summary = Tasks.summary("all", workspace: workspace)
    assert summary["completed"] == 1
    assert summary["text"] =~ "Personal Summary"
  end

  test "cancelled tasks clear pending reminder jobs", %{workspace: workspace} do
    assert {:ok, task} =
             Tasks.add(
               %{
                 "title" => "Cancel me",
                 "due_at" => "2026-03-21T09:30:00Z",
                 "follow_up_at" => "2026-03-22T08:00:00Z"
               },
               workspace: workspace,
               channel: "feishu",
               chat_id: "chat-123"
             )

    if Process.whereis(Nex.Agent.Cron) do
      assert Enum.any?(
               Nex.Agent.Cron.list_jobs(workspace: workspace),
               &String.ends_with?(&1.name, task["id"])
             )
    end

    assert {:ok, cancelled} =
             Tasks.update(task["id"], %{"status" => "cancelled"}, workspace: workspace)

    assert cancelled["status"] == "cancelled"

    if Process.whereis(Nex.Agent.Cron) do
      refute Enum.any?(
               Nex.Agent.Cron.list_jobs(workspace: workspace),
               &String.ends_with?(&1.name, task["id"])
             )
    end
  end

  defp cleanup_task_jobs(prefix, workspace) do
    if Process.whereis(Nex.Agent.Cron) do
      Nex.Agent.Cron.list_jobs(workspace: workspace)
      |> Enum.filter(&String.starts_with?(&1.name, prefix))
      |> Enum.each(fn job -> Nex.Agent.Cron.remove_job(job.id, workspace: workspace) end)
    end
  end
end
