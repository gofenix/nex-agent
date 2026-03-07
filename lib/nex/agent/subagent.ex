defmodule Nex.Agent.Subagent do
  @moduledoc """
  Subagent - Background task execution with independent agent loop.

  Spawns background tasks that run an independent Runner loop with a restricted
  tool set (no message/spawn to prevent recursion). Results are announced back
  to the main agent via the Bus as system inbound messages.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Session}

  @max_subagent_iterations 15

  defstruct tasks: %{}

  @type task_entry :: %{
          id: String.t(),
          label: String.t(),
          description: String.t(),
          status: :running | :completed | :failed | :cancelled,
          pid: pid() | nil,
          session_key: String.t() | nil,
          started_at: integer(),
          completed_at: integer() | nil,
          result: String.t() | nil,
          error: term() | nil
        }

  @type t :: %__MODULE__{
          tasks: %{String.t() => task_entry()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: name)
  end

  @doc """
  Spawn a background subagent task.

  ## Options

  * `:label` - Short label for the task
  * `:session_key` - Session key of the parent (for cancel_by_session)
  * `:provider` - LLM provider atom
  * `:model` - LLM model string
  * `:api_key` - API key
  * `:base_url` - API base URL
  * `:channel` - Origin channel
  * `:chat_id` - Origin chat ID
  """
  @spec spawn_task(String.t(), keyword()) :: {:ok, String.t()}
  def spawn_task(task_description, opts \\ []) do
    GenServer.call(__MODULE__, {:spawn, task_description, opts})
  end

  @doc """
  List all tasks.
  """
  @spec list() :: list(task_entry())
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Get task status by ID.
  """
  @spec status(String.t()) :: task_entry() | nil
  def status(task_id) do
    GenServer.call(__MODULE__, {:status, task_id})
  end

  @doc """
  Cancel a running task by ID.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(task_id) do
    GenServer.call(__MODULE__, {:cancel, task_id})
  end

  @doc """
  Cancel all running tasks for a session key. Returns count cancelled.
  """
  @spec cancel_by_session(String.t()) :: {:ok, non_neg_integer()}
  def cancel_by_session(session_key) do
    GenServer.call(__MODULE__, {:cancel_by_session, session_key})
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:spawn, task_description, opts}, _from, state) do
    task_id = generate_id()
    label = opts[:label] || String.slice(task_description, 0, 30)
    session_key = opts[:session_key]
    server = self()

    pid =
      spawn_link(fn ->
        run_subagent_loop(server, task_id, task_description, label, opts)
      end)

    task = %{
      id: task_id,
      label: label,
      description: task_description,
      status: :running,
      pid: pid,
      session_key: session_key,
      started_at: System.system_time(:second),
      completed_at: nil,
      result: nil,
      error: nil
    }

    new_tasks = Map.put(state.tasks, task_id, task)
    {:reply, {:ok, task_id}, %{state | tasks: new_tasks}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.tasks), state}
  end

  @impl true
  def handle_call({:status, task_id}, _from, state) do
    {:reply, Map.get(state.tasks, task_id), state}
  end

  @impl true
  def handle_call({:cancel, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :running, pid: pid} = task ->
        if pid, do: Process.exit(pid, :kill)
        updated = %{task | status: :cancelled, completed_at: System.system_time(:second)}
        {:reply, :ok, %{state | tasks: Map.put(state.tasks, task_id, updated)}}

      _task ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:cancel_by_session, session_key}, _from, state) do
    {cancelled, new_tasks} =
      Enum.reduce(state.tasks, {0, state.tasks}, fn {id, task}, {count, tasks} ->
        if task.session_key == session_key and task.status == :running do
          if task.pid, do: Process.exit(task.pid, :kill)
          updated = %{task | status: :cancelled, completed_at: System.system_time(:second)}
          {count + 1, Map.put(tasks, id, updated)}
        else
          {count, tasks}
        end
      end)

    {:reply, {:ok, cancelled}, %{state | tasks: new_tasks}}
  end

  @impl true
  def handle_info({:task_complete, task_id, result}, state) do
    state = update_task(state, task_id, :completed, result: result)
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_failed, task_id, reason}, state) do
    state = update_task(state, task_id, :failed, error: reason)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    case find_task_by_pid(state, pid) do
      nil ->
        {:noreply, state}

      {task_id, task} when task.status == :running and reason != :normal ->
        Logger.warning("[Subagent] Task #{task_id} exited: #{inspect(reason)}")
        state = update_task(state, task_id, :failed, error: inspect(reason))
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Subagent loop (runs in spawned process) ---

  defp run_subagent_loop(server, task_id, task_description, label, opts) do
    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    channel = Keyword.get(opts, :channel)
    chat_id = Keyword.get(opts, :chat_id)

    session = Session.new("subagent:#{task_id}")

    runner_opts = [
      provider: provider,
      model: model,
      api_key: api_key,
      base_url: base_url,
      max_iterations: @max_subagent_iterations,
      channel: "system",
      chat_id: task_id,
      tools_filter: :subagent
    ]

    prompt = """
    You are a background subagent. Complete this task and return a concise result.

    Task: #{task_description}
    """

    case Nex.Agent.Runner.run(session, prompt, runner_opts) do
      {:ok, result, _session} ->
        send(server, {:task_complete, task_id, result})
        announce_result(task_id, label, task_description, result, channel, chat_id, :ok)

      {:error, reason, _session} ->
        error_msg = inspect(reason)
        send(server, {:task_failed, task_id, error_msg})
        announce_result(task_id, label, task_description, error_msg, channel, chat_id, :error)
    end
  rescue
    e ->
      error_msg = Exception.message(e)
      send(server, {:task_failed, task_id, error_msg})
  end

  defp announce_result(task_id, label, _task, result, channel, chat_id, status) do
    if Process.whereis(Bus) do
      status_emoji = if status == :ok, do: "\u2705", else: "\u274c"
      content = "#{status_emoji} Subagent [#{label}] finished:\n#{result}"

      Bus.publish(:inbound, %{
        channel: "system",
        chat_id: chat_id || "default",
        content: content,
        metadata: %{
          "subagent_task_id" => task_id,
          "subagent_label" => label,
          "origin_channel" => channel,
          "origin_chat_id" => chat_id
        }
      })
    end
  end

  # --- Helpers ---

  defp update_task(state, task_id, new_status, fields) do
    case Map.get(state.tasks, task_id) do
      nil ->
        state

      task ->
        updated =
          task
          |> Map.put(:status, new_status)
          |> Map.put(:completed_at, System.system_time(:second))
          |> Map.merge(Map.new(fields))

        Bus.publish(:subagent, %{
          type: new_status,
          task_id: task_id,
          result: updated[:result],
          error: updated[:error]
        })

        %{state | tasks: Map.put(state.tasks, task_id, updated)}
    end
  end

  defp find_task_by_pid(state, pid) do
    Enum.find(state.tasks, fn {_id, task} -> task.pid == pid end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
