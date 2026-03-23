defmodule Nex.Automation.ServerTest do
  use ExUnit.Case, async: false

  alias Nex.Automation.{Server, Workflow, WorkspaceManager}
  alias Nex.Automation.Tracker.GitHub

  setup do
    {:ok, tracker_state} = Agent.start_link(fn -> %{ready: [], issues: %{}} end)
    {:ok, workspace_state} = Agent.start_link(fn -> %{prepared: [], cleaned: []} end)
    {:ok, worker_state} = Agent.start_link(fn -> %{running: %{}, cancelled: []} end)
    status_dir = temp_dir("orchestrator-status")

    on_exit(fn ->
      File.rm_rf!(status_dir)
      Process.exit(tracker_state, :normal)
      Process.exit(workspace_state, :normal)
      Process.exit(worker_state, :normal)
    end)

    workflow = %Workflow{
      repo_root: status_dir,
      prompt_template: "Follow the repo workflow.",
      tracker: %Workflow.Tracker{
        kind: :github,
        owner: "openai",
        repo: "symphony",
        ready_labels: ["agent:ready"],
        running_label: "nex:running",
        review_label: "nex:review",
        failed_label: "nex:failed"
      },
      polling: %Workflow.Polling{interval_ms: 60_000},
      workspace: %Workflow.Workspace{
        root: Path.join(status_dir, "worktrees"),
        agent_root: Path.join(status_dir, "agents")
      },
      agent: %Workflow.Agent{max_concurrent_agents: 1, max_retry_backoff_ms: 300_000},
      worker: %Workflow.Worker{command: ["mix", "nex.agent"], timeout_ms: 5_000}
    }

    {:ok,
     tracker_state: tracker_state,
     workspace_state: workspace_state,
     worker_state: worker_state,
     workflow: workflow,
     status_dir: status_dir}
  end

  test "poll claims a ready issue, runs it, marks review, and writes status snapshot", ctx do
    issue = %GitHub.Issue{
      number: 7,
      title: "Fix auth flow",
      body: "Please automate this",
      html_url: "https://github.com/openai/symphony/issues/7",
      state: "open",
      labels: ["agent:ready"]
    }

    Agent.update(ctx.tracker_state, fn _ -> %{ready: [issue], issues: %{7 => issue}} end)

    {:ok, pid} =
      Server.start_link(
        workflow: ctx.workflow,
        tracker: {__MODULE__.FakeTracker, [state: ctx.tracker_state]},
        workspace_manager: {__MODULE__.FakeWorkspaceManager, [state: ctx.workspace_state]},
        worker_runner: {__MODULE__.FakeWorkerRunner, [state: ctx.worker_state, mode: :complete]}
      )

    assert :ok = Server.poll_now(pid)

    eventually(fn ->
      {:ok, snapshot} = Server.status(pid)
      assert snapshot.running == []
      assert snapshot.completed == [7]
    end)

    status_path = Path.join(ctx.status_dir, ".nex/orchestrator/status.json")
    assert File.exists?(status_path)
    assert File.read!(status_path) =~ "\"completed\":[7]"

    assert Agent.get(ctx.tracker_state, fn state -> state.issues[7].labels end) == ["nex:review"]
    assert Agent.get(ctx.workspace_state, & &1.cleaned) == [7]
  end

  test "poll cancels a running issue when the running label disappears", ctx do
    issue = %GitHub.Issue{
      number: 13,
      title: "Tighten labels",
      body: "Please automate this",
      html_url: "https://github.com/openai/symphony/issues/13",
      state: "open",
      labels: ["agent:ready"]
    }

    Agent.update(ctx.tracker_state, fn _ -> %{ready: [issue], issues: %{13 => issue}} end)

    {:ok, pid} =
      Server.start_link(
        workflow: ctx.workflow,
        tracker: {__MODULE__.FakeTracker, [state: ctx.tracker_state]},
        workspace_manager: {__MODULE__.FakeWorkspaceManager, [state: ctx.workspace_state]},
        worker_runner: {__MODULE__.FakeWorkerRunner, [state: ctx.worker_state, mode: :manual]}
      )

    assert :ok = Server.poll_now(pid)

    Agent.update(ctx.tracker_state, fn state ->
      %{
        state
        | ready: [],
          issues: %{13 => %GitHub.Issue{issue | labels: [], state: "open"}}
      }
    end)

    assert :ok = Server.poll_now(pid)

    eventually(fn ->
      {:ok, snapshot} = Server.status(pid)
      assert snapshot.cancelled == [13]
    end)

    assert Agent.get(ctx.worker_state, & &1.cancelled) == [13]
    assert Agent.get(ctx.workspace_state, & &1.cleaned) == [13]
  end

  test "poll marks an issue failed when workspace preparation fails after claiming it", ctx do
    issue = %GitHub.Issue{
      number: 21,
      title: "Workspace setup fails",
      body: "Please automate this",
      html_url: "https://github.com/openai/symphony/issues/21",
      state: "open",
      labels: ["agent:ready"]
    }

    Agent.update(ctx.tracker_state, fn _ -> %{ready: [issue], issues: %{21 => issue}} end)

    {:ok, pid} =
      Server.start_link(
        workflow: ctx.workflow,
        tracker: {__MODULE__.FakeTracker, [state: ctx.tracker_state]},
        workspace_manager: __MODULE__.FailingWorkspaceManager,
        worker_runner: {__MODULE__.FakeWorkerRunner, [state: ctx.worker_state, mode: :manual]}
      )

    assert :ok = Server.poll_now(pid)

    eventually(fn ->
      {:ok, snapshot} = Server.status(pid)
      assert snapshot.failed == [21]
      assert snapshot.running == []
    end)

    assert Agent.get(ctx.tracker_state, fn state -> state.issues[21].labels end) == ["nex:failed"]
  end

  test "poll marks an issue failed and cleans the workspace when worker startup fails", ctx do
    issue = %GitHub.Issue{
      number: 34,
      title: "Worker start fails",
      body: "Please automate this",
      html_url: "https://github.com/openai/symphony/issues/34",
      state: "open",
      labels: ["agent:ready"]
    }

    Agent.update(ctx.tracker_state, fn _ -> %{ready: [issue], issues: %{34 => issue}} end)

    {:ok, pid} =
      Server.start_link(
        workflow: ctx.workflow,
        tracker: {__MODULE__.FakeTracker, [state: ctx.tracker_state]},
        workspace_manager: {__MODULE__.FakeWorkspaceManager, [state: ctx.workspace_state]},
        worker_runner: __MODULE__.FailingWorkerRunner
      )

    assert :ok = Server.poll_now(pid)

    eventually(fn ->
      {:ok, snapshot} = Server.status(pid)
      assert snapshot.failed == [34]
      assert snapshot.running == []
    end)

    assert Agent.get(ctx.tracker_state, fn state -> state.issues[34].labels end) == ["nex:failed"]
    assert Agent.get(ctx.workspace_state, & &1.cleaned) == [34]
  end

  defmodule FakeTracker do
    def ready_issues(_workflow, opts) do
      state = Keyword.fetch!(opts, :state)
      {:ok, Agent.get(state, & &1.ready)}
    end

    def issue(_workflow, issue_number, opts) do
      state = Keyword.fetch!(opts, :state)
      {:ok, Agent.get(state, &get_in(&1, [:issues, issue_number]))}
    end

    def mark_running(_workflow, issue, opts) do
      state = Keyword.fetch!(opts, :state)
      updated = %{issue | labels: ["nex:running"]}
      Agent.update(state, &put_in(&1, [:issues, issue.number], updated))
      {:ok, updated}
    end

    def mark_review(_workflow, issue, opts) do
      state = Keyword.fetch!(opts, :state)
      updated = %{issue | labels: ["nex:review"]}
      Agent.update(state, &put_in(&1, [:issues, issue.number], updated))
      {:ok, updated}
    end

    def mark_failed(_workflow, issue, opts) do
      state = Keyword.fetch!(opts, :state)
      updated = %{issue | labels: ["nex:failed"]}
      Agent.update(state, &put_in(&1, [:issues, issue.number], updated))
      {:ok, updated}
    end
  end

  defmodule FakeWorkspaceManager do
    def prepare(_workflow, issue, opts) do
      state = Keyword.fetch!(opts, :state)

      Agent.update(state, fn current ->
        %{current | prepared: [issue.number | current.prepared]}
      end)

      {:ok,
       %WorkspaceManager.Workspace{
         issue_number: issue.number,
         branch: "nex/#{issue.number}",
         code_path: "/tmp/code/#{issue.number}",
         agent_path: "/tmp/agent/#{issue.number}",
         repo_root: "/tmp/repo"
       }}
    end

    def cleanup(workspace, opts) do
      state = Keyword.fetch!(opts, :state)

      Agent.update(state, fn current ->
        %{current | cleaned: [workspace.issue_number | current.cleaned]}
      end)

      :ok
    end
  end

  defmodule FakeWorkerRunner do
    def start_link(opts) do
      state = Keyword.fetch!(opts, :state)
      mode = Keyword.fetch!(opts, :mode)
      id = Keyword.fetch!(opts, :id)
      notify = Keyword.fetch!(opts, :notify)

      pid =
        spawn(fn ->
          if mode == :complete do
            send(
              notify,
              {:worker_finished, id, %{status: :completed, exit_code: 0, output: "done"}}
            )
          else
            Process.sleep(:infinity)
          end
        end)

      Agent.update(state, fn current -> put_in(current, [:running, id], pid) end)

      {:ok, pid}
    end

    def cancel(pid, opts) do
      state = Keyword.fetch!(opts, :state)

      Agent.update(state, fn current ->
        %{current | cancelled: [extract_issue_number(pid, current) | current.cancelled]}
      end)

      Process.exit(pid, :kill)
      :ok
    end

    defp extract_issue_number(pid, current) do
      current.running
      |> Enum.find_value(fn {issue_number, worker_pid} ->
        if worker_pid == pid, do: issue_number
      end)
    end
  end

  defmodule FailingWorkspaceManager do
    def prepare(_workflow, _issue, _opts), do: {:error, :workspace_failed}
    def cleanup(_workspace, _opts), do: :ok
  end

  defmodule FailingWorkerRunner do
    def start_link(_opts), do: {:error, :worker_start_failed}
    def cancel(_pid, _opts), do: :ok
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    try do
      fun.()
    rescue
      ExUnit.AssertionError ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end

  defp temp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
