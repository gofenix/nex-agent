defmodule Nex.Agent.Cron do
  @moduledoc """
  定时任务 - 简单的 cron 实现
  """

  use GenServer

  @jobs_file Path.join(System.get_env("HOME", "~"), ".nex/agent/cron/jobs.json")

  defstruct [:id, :name, :schedule, :message, :enabled, :last_run, :next_run]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          schedule: map(),
          message: String.t(),
          enabled: boolean(),
          last_run: integer() | nil,
          next_run: integer() | nil
        }

  @doc """
  启动 Cron 服务
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  @doc """
  添加定时任务

  ## 参数

  * `name` - 任务名称
  * `schedule` - 调度配置 `%{type: :every, seconds: 60}` 或 `%{type: :cron, expr: "0 9 * * *"}`
  * `message` - 要发送给 agent 的消息
  """
  @spec add_job(String.t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def add_job(name, schedule, message) do
    GenServer.call(__MODULE__, {:add_job, name, schedule, message})
  end

  @doc """
  移除定时任务
  """
  @spec remove_job(String.t()) :: :ok | {:error, :not_found}
  def remove_job(job_id) do
    GenServer.call(__MODULE__, {:remove_job, job_id})
  end

  @doc """
  列出所有定时任务
  """
  @spec list_jobs() :: [t()]
  def list_jobs do
    GenServer.call(__MODULE__, :list_jobs)
  end

  @doc """
  启用/禁用任务
  """
  @spec enable_job(String.t(), boolean()) :: {:ok, t()} | {:error, :not_found}
  def enable_job(job_id, enabled) do
    GenServer.call(__MODULE__, {:enable_job, job_id, enabled})
  end

  @doc """
  手动运行任务
  """
  @spec run_job(String.t()) :: :ok | {:error, :not_found}
  def run_job(job_id) do
    GenServer.call(__MODULE__, {:run_job, job_id})
  end

  @doc """
  获取任务状态
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    jobs = load_jobs()
    schedule_tick()
    {:ok, %{jobs: jobs, callbacks: %{}, on_job: nil}}
  end

  @impl true
  def handle_call({:add_job, name, schedule, message}, _from, state) do
    job = %__MODULE__{
      id: generate_id(),
      name: name,
      schedule: schedule,
      message: message,
      enabled: true,
      last_run: nil,
      next_run: calculate_next_run(schedule)
    }

    jobs = [job | state.jobs]
    save_jobs(jobs)
    {:reply, {:ok, job}, %{state | jobs: jobs}}
  end

  @impl true
  def handle_call({:remove_job, job_id}, _from, state) do
    case Enum.split_with(state.jobs, fn j -> j.id == job_id end) do
      {[_], remaining} ->
        save_jobs(remaining)
        {:reply, :ok, %{state | jobs: remaining}}

      {[], _} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_jobs, _from, state) do
    {:reply, state.jobs, state}
  end

  @impl true
  def handle_call({:enable_job, job_id, enabled}, _from, state) do
    case Enum.split_with(state.jobs, fn j -> j.id == job_id end) do
      {[job], remaining} ->
        updated_job = %{job | enabled: enabled}
        jobs = [updated_job | remaining]
        save_jobs(jobs)
        {:reply, {:ok, updated_job}, %{state | jobs: jobs}}

      {[], _} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:run_job, job_id}, _from, state) do
    job = Enum.find(state.jobs, fn j -> j.id == job_id end)

    if job do
      execute_job(job)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      total: length(state.jobs),
      enabled: Enum.count(state.jobs, & &1.enabled),
      disabled: Enum.count(state.jobs, &(not &1.enabled))
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.system_time(:second)

    jobs_to_run =
      state.jobs
      |> Enum.filter(fn job ->
        job.enabled and job.next_run != nil and job.next_run <= now
      end)

    Enum.each(jobs_to_run, &execute_job/1)

    updated_jobs =
      state.jobs
      |> Enum.map(fn job ->
        if job in jobs_to_run do
          %{job | last_run: now, next_run: calculate_next_run(job.schedule)}
        else
          job
        end
      end)

    save_jobs(updated_jobs)
    schedule_tick()
    {:noreply, %{state | jobs: updated_jobs}}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, 1000)
  end

  defp execute_job(job) do
    spawn(fn ->
      case Nex.Agent.Bus.subscribers(:cron) do
        [] ->
          :ok

        pids ->
          Enum.each(pids, fn pid ->
            send(pid, {:cron_job, job})
          end)
      end
    end)
  end

  defp calculate_next_run(%{type: :every, seconds: seconds}) do
    System.system_time(:second) + seconds
  end

  defp calculate_next_run(%{type: :at, timestamp: timestamp}) do
    timestamp
  end

  defp calculate_next_run(%{type: :cron, expr: _expr}) do
    now = System.system_time(:second)
    now + 60
  end

  defp calculate_next_run(_), do: nil

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp load_jobs do
    if File.exists?(@jobs_file) do
      case File.read!(@jobs_file) |> Jason.decode() do
        jobs when is_list(jobs) ->
          Enum.map(jobs, fn j ->
            %__MODULE__{
              id: j["id"],
              name: j["name"],
              schedule: j["schedule"],
              message: j["message"],
              enabled: j["enabled"],
              last_run: j["last_run"],
              next_run: j["next_run"]
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp save_jobs(jobs) do
    File.mkdir_p!(Path.dirname(@jobs_file))

    data =
      Enum.map(jobs, fn j ->
        %{
          "id" => j.id,
          "name" => j.name,
          "schedule" => j.schedule,
          "message" => j.message,
          "enabled" => j.enabled,
          "last_run" => j.last_run,
          "next_run" => j.next_run
        }
      end)

    File.write!(@jobs_file, Jason.encode!(data, pretty: true))
  end
end
