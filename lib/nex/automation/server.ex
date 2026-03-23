defmodule Nex.Automation.Server do
  @moduledoc false

  use GenServer

  alias Nex.Automation.{Workflow, WorkerRunner, WorkspaceManager}
  alias Nex.Automation.Tracker.GitHub

  defstruct [
    :workflow,
    :status_path,
    :tracker,
    :tracker_opts,
    :workspace_manager,
    :workspace_opts,
    :worker_runner,
    :worker_opts,
    :poll_timer,
    :last_poll_at,
    runs: %{},
    completed: [],
    failed: [],
    cancelled: []
  ]

  @type t :: %__MODULE__{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec poll_now(pid()) :: :ok
  def poll_now(pid) do
    GenServer.call(pid, :poll_now, 30_000)
  end

  @spec status(pid()) :: {:ok, map()}
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @impl true
  def init(opts) do
    workflow = Keyword.fetch!(opts, :workflow)
    {tracker, tracker_opts} = resolve_adapter(Keyword.get(opts, :tracker), GitHub)

    {workspace_manager, workspace_opts} =
      resolve_adapter(Keyword.get(opts, :workspace_manager), WorkspaceManager)

    {worker_runner, worker_opts} =
      resolve_adapter(Keyword.get(opts, :worker_runner), WorkerRunner)

    status_path = Keyword.get(opts, :status_path, default_status_path(workflow))

    state = %__MODULE__{
      workflow: workflow,
      status_path: status_path,
      tracker: tracker,
      tracker_opts: tracker_opts,
      workspace_manager: workspace_manager,
      workspace_opts: workspace_opts,
      worker_runner: worker_runner,
      worker_opts: worker_opts
    }

    {:ok, schedule_poll(write_status(state))}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    {:reply, :ok, state |> cancel_poll_timer() |> poll() |> schedule_poll()}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, snapshot(state)}, state}
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply, state |> poll() |> schedule_poll()}
  end

  @impl true
  def handle_info({:worker_finished, issue_number, result}, state) do
    case Map.pop(state.runs, issue_number) do
      {nil, _runs} ->
        {:noreply, state}

      {run, remaining_runs} ->
        state = %{state | runs: remaining_runs}
        state = finalize_run(state, run, result)
        {:noreply, write_status(state)}
    end
  end

  defp poll(state) do
    state
    |> reconcile_running_runs()
    |> start_ready_issues()
    |> Map.put(:last_poll_at, now_iso())
    |> write_status()
  end

  defp reconcile_running_runs(state) do
    Enum.reduce(Map.values(state.runs), state, fn run, acc ->
      case acc.tracker.issue(acc.workflow, run.issue.number, acc.tracker_opts) do
        {:ok, %GitHub.Issue{state: "open", labels: labels} = refreshed} ->
          if acc.workflow.tracker.running_label in labels do
            put_in(acc.runs[run.issue.number].issue, refreshed)
          else
            cancel_run(acc, run)
          end

        {:ok, _issue} ->
          cancel_run(acc, run)

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp start_ready_issues(state) do
    available_slots = max(state.workflow.agent.max_concurrent_agents - map_size(state.runs), 0)

    case state.tracker.ready_issues(state.workflow, state.tracker_opts) do
      {:ok, issues} ->
        issues
        |> Enum.reject(&Map.has_key?(state.runs, &1.number))
        |> Enum.take(available_slots)
        |> Enum.reduce(state, &start_issue_run/2)

      {:error, _reason} ->
        state
    end
  end

  defp start_issue_run(issue, state) do
    case state.tracker.mark_running(state.workflow, issue, state.tracker_opts) do
      {:ok, running_issue} ->
        start_claimed_issue(state, running_issue)

      {:error, _reason} ->
        state
    end
  end

  defp start_claimed_issue(state, running_issue) do
    case state.workspace_manager.prepare(state.workflow, running_issue, state.workspace_opts) do
      {:ok, workspace} ->
        case state.worker_runner.start_link(
               state.worker_opts ++
                 [
                   id: running_issue.number,
                   command: build_worker_command(state.workflow, workspace, running_issue),
                   cwd: workspace.code_path,
                   notify: self(),
                   timeout_ms: state.workflow.worker.timeout_ms
                 ]
             ) do
          {:ok, worker_pid} ->
            run = %{issue: running_issue, workspace: workspace, worker_pid: worker_pid}
            put_in(state.runs[running_issue.number], run)

          {:error, _reason} ->
            fail_claimed_issue(state, running_issue, workspace)
        end

      {:error, _reason} ->
        fail_claimed_issue(state, running_issue)
    end
  end

  defp fail_claimed_issue(state, issue, workspace \\ nil) do
    if workspace do
      _ = state.workspace_manager.cleanup(workspace, state.workspace_opts)
    end

    latest_issue =
      case state.tracker.issue(state.workflow, issue.number, state.tracker_opts) do
        {:ok, refreshed_issue} -> refreshed_issue
        _ -> issue
      end

    _ = state.tracker.mark_failed(state.workflow, latest_issue, state.tracker_opts)

    Map.update!(state, :failed, &Enum.uniq([issue.number | &1]))
  end

  defp cancel_run(state, run) do
    _ = state.worker_runner.cancel(run.worker_pid, state.worker_opts)
    _ = state.workspace_manager.cleanup(run.workspace, state.workspace_opts)

    state
    |> Map.update!(:runs, &Map.delete(&1, run.issue.number))
    |> Map.update!(:cancelled, &Enum.uniq([run.issue.number | &1]))
    |> write_status()
  end

  defp finalize_run(state, run, %{status: :completed}) do
    _ = state.workspace_manager.cleanup(run.workspace, state.workspace_opts)

    state =
      case state.tracker.issue(state.workflow, run.issue.number, state.tracker_opts) do
        {:ok, latest_issue} ->
          _ = state.tracker.mark_review(state.workflow, latest_issue, state.tracker_opts)
          state

        _ ->
          state
      end

    Map.update!(state, :completed, &Enum.uniq([run.issue.number | &1]))
  end

  defp finalize_run(state, run, %{status: :cancelled}) do
    _ = state.workspace_manager.cleanup(run.workspace, state.workspace_opts)
    Map.update!(state, :cancelled, &Enum.uniq([run.issue.number | &1]))
  end

  defp finalize_run(state, run, _result) do
    _ = state.workspace_manager.cleanup(run.workspace, state.workspace_opts)

    state =
      case state.tracker.issue(state.workflow, run.issue.number, state.tracker_opts) do
        {:ok, latest_issue} ->
          _ = state.tracker.mark_failed(state.workflow, latest_issue, state.tracker_opts)
          state

        _ ->
          state
      end

    Map.update!(state, :failed, &Enum.uniq([run.issue.number | &1]))
  end

  defp build_worker_command(workflow, workspace, issue) do
    workflow.worker.command ++
      [
        "-w",
        workspace.agent_path,
        "-m",
        render_prompt(workflow, issue)
      ]
  end

  defp render_prompt(workflow, issue) do
    labels = Enum.join(issue.labels || [], ", ")

    """
    GitHub issue ##{issue.number}: #{issue.title}
    URL: #{issue.html_url}
    Labels: #{labels}

    Issue body:
    #{issue.body || "(empty)"}

    Repo workflow:
    #{workflow.prompt_template}
    """
    |> String.trim()
  end

  defp schedule_poll(state) do
    ref = Process.send_after(self(), :poll, state.workflow.polling.interval_ms)
    %{state | poll_timer: ref}
  end

  defp cancel_poll_timer(%__MODULE__{poll_timer: nil} = state), do: state

  defp cancel_poll_timer(%__MODULE__{poll_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | poll_timer: nil}
  end

  defp snapshot(state) do
    %{
      workflow_path: state.workflow.path,
      last_poll_at: state.last_poll_at,
      running: state.runs |> Map.keys() |> Enum.sort(),
      completed: Enum.sort(state.completed),
      failed: Enum.sort(state.failed),
      cancelled: Enum.sort(state.cancelled)
    }
  end

  defp write_status(state) do
    File.mkdir_p!(Path.dirname(state.status_path))
    File.write!(state.status_path, Jason.encode!(snapshot(state)))
    state
  end

  defp default_status_path(%Workflow{repo_root: repo_root}) do
    Path.join(repo_root, ".nex/orchestrator/status.json")
  end

  defp resolve_adapter({module, opts}, _default) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp resolve_adapter(nil, default), do: {default, []}
  defp resolve_adapter(module, _default) when is_atom(module), do: {module, []}

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
