defmodule Nex.Agent.ExecutorTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Executor, ProjectMemory}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-executor-#{System.unique_integer([:positive])}")

    Nex.Agent.Onboarding.ensure_initialized()
    Nex.Agent.Workspace.ensure!(workspace: workspace)

    File.write!(
      Path.join(workspace, "executors/codex_cli.json"),
      Jason.encode!(%{
        "enabled" => true,
        "command" => "cat",
        "args" => [],
        "prompt_mode" => "stdin",
        "timeout" => 5
      })
    )

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "dispatches external and local executor runs and records project memory", %{
    workspace: workspace
  } do
    status = Executor.executor_status("codex_cli", workspace: workspace)
    assert status["configured"] == true
    assert status["available"] == true
    assert Executor.preferred_executor(workspace: workspace) == "codex_cli"

    assert {:ok, external_run} =
             Executor.dispatch(
               %{
                 "task" => "echo roadmap status",
                 "executor" => "codex_cli",
                 "cwd" => workspace,
                 "project" => "nex-agent"
               },
               workspace: workspace
             )

    assert external_run["status"] == "completed"
    assert external_run["output"] == "echo roadmap status"
    assert File.exists?(Path.join(workspace, "executors/runs.jsonl"))
    assert [%{"executor" => "codex_cli"} | _] = Executor.recent_runs(workspace: workspace)

    assert [%{"executor" => "codex_cli"} | _] =
             ProjectMemory.recent_runs("nex-agent", workspace: workspace)

    assert {:ok, local_run} =
             Executor.dispatch(
               %{
                 "task" => "apply a tiny glue patch",
                 "executor" => "nex_local",
                 "cwd" => workspace
               },
               workspace: workspace
             )

    assert local_run["status"] == "accepted"
    assert local_run["output"] =~ "nex_local selected"
  end

  test "get_run can retrieve records older than the recent status window", %{workspace: workspace} do
    runs =
      for idx <- 1..205 do
        {:ok, run} =
          Executor.dispatch(
            %{
              "task" => "echo run #{idx}",
              "executor" => "codex_cli",
              "cwd" => workspace
            },
            workspace: workspace
          )

        run
      end

    oldest = hd(runs)

    assert oldest["task"] == "echo run 1"
    assert Executor.get_run(oldest["id"], workspace: workspace)["task"] == "echo run 1"
  end
end
