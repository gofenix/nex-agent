defmodule Nex.Agent.CronWorkspaceTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Cron, Workspace}

  setup do
    workspace_a =
      Path.join(System.tmp_dir!(), "nex-agent-cron-a-#{System.unique_integer([:positive])}")

    workspace_b =
      Path.join(System.tmp_dir!(), "nex-agent-cron-b-#{System.unique_integer([:positive])}")

    Workspace.ensure!(workspace: workspace_a)
    Workspace.ensure!(workspace: workspace_b)

    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(Cron) == nil do
      start_supervised!({Cron, name: Cron})
    end

    Bus.subscribe(:inbound)

    on_exit(fn ->
      Bus.unsubscribe(:inbound)

      Enum.each([workspace_a, workspace_b], fn workspace ->
        if Process.whereis(Cron) do
          Cron.list_jobs(workspace: workspace)
          |> Enum.each(fn job -> Cron.remove_job(job.id, workspace: workspace) end)
        end

        File.rm_rf!(workspace)
      end)
    end)

    {:ok, workspace_a: workspace_a, workspace_b: workspace_b}
  end

  test "jobs stay isolated per workspace and cron execution preserves workspace in payload", %{
    workspace_a: workspace_a,
    workspace_b: workspace_b
  } do
    {:ok, job_a} =
      Cron.add_job(
        %{
          name: "workspace-a-job",
          message: "run in workspace a",
          channel: "feishu",
          chat_id: "chat-a",
          schedule: %{type: :at, timestamp: System.system_time(:second) + 3600},
          delete_after_run: true
        },
        workspace: workspace_a
      )

    {:ok, job_b} =
      Cron.add_job(
        %{
          name: "workspace-b-job",
          message: "run in workspace b",
          channel: "feishu",
          chat_id: "chat-b",
          schedule: %{type: :at, timestamp: System.system_time(:second) + 3600},
          delete_after_run: true
        },
        workspace: workspace_b
      )

    assert Enum.map(Cron.list_jobs(workspace: workspace_a), & &1.id) == [job_a.id]
    assert Enum.map(Cron.list_jobs(workspace: workspace_b), & &1.id) == [job_b.id]

    assert {:ok, _ran_job} = Cron.run_job(job_a.id, workspace: workspace_a)

    assert_receive {:bus_message, :inbound, payload}
    assert payload.workspace == Path.expand(workspace_a)
    assert payload.chat_id == "chat-a"
    assert get_in(payload, [:metadata, "_from_cron"]) == true

    refute Enum.any?(Cron.list_jobs(workspace: workspace_a), &(&1.id == job_a.id))
    assert Enum.any?(Cron.list_jobs(workspace: workspace_b), &(&1.id == job_b.id))
  end
end
