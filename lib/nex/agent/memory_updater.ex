defmodule Nex.Agent.MemoryUpdater do
  @moduledoc false

  use GenServer
  require Logger

  alias Nex.Agent.{Memory, Session, SessionManager, Workspace}

  defstruct current: nil, order: :queue.new(), pending: %{}

  @type job :: %{
          key: {String.t(), String.t()},
          session: Session.t(),
          workspace: String.t(),
          provider: atom(),
          model: String.t(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          req_llm_generate_text_fun: any(),
          llm_call_fun: any()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enqueue(Session.t(), keyword()) :: :ok
  def enqueue(%Session{} = session, opts \\ []) do
    GenServer.cast(__MODULE__, {:enqueue, build_job(session, opts)})
  end

  @spec status(String.t(), keyword()) :: map()
  def status(session_key, opts \\ []) do
    GenServer.call(__MODULE__, {:status, runtime_key(session_key, opts)})
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:status, key}, _from, state) do
    reply =
      cond do
        match?(%{key: ^key}, state.current) ->
          %{"status" => "running", "queued" => queue_size_for(state, key)}

        Map.has_key?(state.pending, key) ->
          %{"status" => "queued", "queued" => queue_size_for(state, key)}

        true ->
          %{"status" => "idle", "queued" => 0}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:enqueue, job}, state) do
    key = job.key

    state =
      cond do
        match?(%{key: ^key}, state.current) and Map.has_key?(state.pending, key) ->
          %{state | pending: Map.put(state.pending, key, job)}

        match?(%{key: ^key}, state.current) ->
          %{
            state
            | order: :queue.in(key, state.order),
              pending: Map.put(state.pending, key, job)
          }

        Map.has_key?(state.pending, key) ->
          %{state | pending: Map.put(state.pending, key, job)}

        true ->
          %{
            state
            | order: :queue.in(key, state.order),
              pending: Map.put(state.pending, key, job)
          }
      end

    {:noreply, maybe_start_next(state)}
  end

  @impl true
  def handle_info({:job_finished, key, result}, state) do
    log_job_result(key, result)
    next_state = %{state | current: nil}
    {:noreply, maybe_start_next(next_state)}
  end

  defp maybe_start_next(%__MODULE__{current: nil} = state) do
    case dequeue_next_job(state.order, state.pending) do
      {:ok, job, order, pending} ->
        parent = self()

        {:ok, _pid} =
          Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
            result = run_job(job)
            send(parent, {:job_finished, job.key, result})
          end)

        %{state | current: job, order: order, pending: pending}

      :empty ->
        state
    end
  end

  defp maybe_start_next(state), do: state

  defp dequeue_next_job(order, pending) do
    case :queue.out(order) do
      {{:value, key}, rest} ->
        case Map.pop(pending, key) do
          {nil, pending} -> dequeue_next_job(rest, pending)
          {job, pending} -> {:ok, job, rest, pending}
        end

      {:empty, _} ->
        :empty
    end
  end

  defp run_job(job) do
    opts =
      [
        workspace: job.workspace,
        api_key: job.api_key,
        base_url: job.base_url
      ]
      |> maybe_put(:req_llm_generate_text_fun, job.req_llm_generate_text_fun)
      |> maybe_put(:llm_call_fun, job.llm_call_fun)

    case Memory.refresh(job.session, job.provider, job.model, opts) do
      {:ok, updated_session, status} ->
        updated_session
        |> sanitize_session_for_persistence()
        |> SessionManager.save_sync(workspace: job.workspace)

        {:ok, status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_job_result({workspace, session_key}, {:ok, status}) do
    Logger.info(
      "[MemoryUpdater] workspace=#{workspace} session=#{session_key} completed status=#{status}"
    )
  end

  defp log_job_result({workspace, session_key}, {:error, reason}) do
    Logger.warning(
      "[MemoryUpdater] workspace=#{workspace} session=#{session_key} failed reason=#{inspect(reason)}"
    )
  end

  defp build_job(%Session{} = session, opts) do
    workspace = Keyword.get(opts, :workspace, Workspace.root())
    session_key = session.key
    runtime_metadata = session.metadata || %{}

    %{
      key: {Path.expand(workspace), session_key},
      session: session,
      workspace: workspace,
      provider: Keyword.get(opts, :provider, :anthropic),
      model: Keyword.get(opts, :model, "claude-sonnet-4-20250514"),
      api_key: Keyword.get(opts, :api_key),
      base_url: Keyword.get(opts, :base_url),
      req_llm_generate_text_fun:
        Keyword.get(opts, :req_llm_generate_text_fun) ||
          Map.get(runtime_metadata, "memory_refresh_req_llm_generate_text_fun"),
      llm_call_fun:
        Keyword.get(opts, :llm_call_fun) || Map.get(runtime_metadata, "memory_refresh_llm_call_fun")
    }
  end

  defp runtime_key(session_key, opts) do
    workspace = Keyword.get(opts, :workspace, Workspace.root())
    {Path.expand(workspace), session_key}
  end

  defp queue_size_for(state, key) do
    if Map.has_key?(state.pending, key), do: 1, else: 0
  end

  defp sanitize_session_for_persistence(%Session{} = session) do
    metadata =
      session.metadata
      |> Kernel.||(%{})
      |> Map.delete("memory_refresh_llm_call_fun")
      |> Map.delete("memory_refresh_req_llm_generate_text_fun")

    %{session | metadata: metadata}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
