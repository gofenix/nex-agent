defmodule Nex.Agent.Gateway do
  @moduledoc """
  Gateway - 后台服务管理

  负责：
  - 启动/停止 Bus
  - 启动/停止 Cron
  - 管理 Agent 进程
  - 提供 HTTP API（可选）
  """

  use GenServer

  defstruct [:config, :status, :started_at]

  @type status :: :stopped | :starting | :running | :stopping

  @type t :: %__MODULE__{
          config: Nex.Agent.Config.t(),
          status: status(),
          started_at: integer() | nil
        }

  @doc """
  启动 Gateway
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  启动所有服务
  """
  @spec start() :: :ok | {:error, term()}
  def start do
    GenServer.call(__MODULE__, :start, :infinity)
  end

  @doc """
  停止所有服务
  """
  @spec stop() :: :ok
  def stop do
    GenServer.call(__MODULE__, :stop, :infinity)
  end

  @doc """
  获取状态
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  发送消息给 Agent
  """
  @spec send_message(String.t()) :: {:ok, String.t()} | {:error, term()}
  def send_message(message) do
    GenServer.call(__MODULE__, {:send_message, message}, :infinity)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      config: Nex.Agent.Config.load(),
      status: :stopped,
      started_at: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:start, _from, %{status: :stopped} = state) do
    case do_start(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:start, _from, state) do
    {:reply, {:error, :already_started}, state}
  end

  @impl true
  def handle_call(:stop, _from, %{status: :running} = state) do
    new_state = do_stop(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      status: state.status,
      started_at: state.started_at,
      config: %{
        provider: state.config.provider,
        model: state.config.model
      },
      services: %{
        bus: Process.whereis(Nex.Agent.Bus) != nil,
        cron: Process.whereis(Nex.Agent.Cron) != nil
      }
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:send_message, message}, _from, %{status: :running} = state) do
    case do_send_message(state, message) do
      {:ok, response} ->
        {:reply, {:ok, response}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:send_message, _message}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  defp do_start(state) do
    if not Nex.Agent.Config.valid?(state.config) do
      {:error, :invalid_config}
    else
      ensure_bus_started()
      ensure_cron_started()

      {:ok,
       %{
         state
         | status: :running,
           started_at: System.system_time(:second)
       }}
    end
  end

  defp do_stop(state) do
    stop_cron()
    stop_bus()

    %{state | status: :stopped, started_at: nil}
  end

  defp ensure_bus_started do
    case Process.whereis(Nex.Agent.Bus) do
      nil ->
        {:ok, _} = Nex.Agent.Bus.start_link()
        :ok

      _pid ->
        :ok
    end
  end

  defp ensure_cron_started do
    case Process.whereis(Nex.Agent.Cron) do
      nil ->
        {:ok, _} = Nex.Agent.Cron.start_link()
        :ok

      _pid ->
        :ok
    end
  end

  defp stop_bus do
    case Process.whereis(Nex.Agent.Bus) do
      nil -> :ok
      pid -> GenServer.stop(pid, :shutdown)
    end
  end

  defp stop_cron do
    case Process.whereis(Nex.Agent.Cron) do
      nil -> :ok
      pid -> GenServer.stop(pid, :shutdown)
    end
  end

  defp do_send_message(_state, message) do
    config = Nex.Agent.Config.load()

    api_key = Nex.Agent.Config.get_current_api_key(config)
    base_url = Nex.Agent.Config.get_current_base_url(config)

    opts = [
      provider: String.to_atom(config.provider),
      model: config.model,
      api_key: api_key,
      base_url: base_url
    ]

    case Nex.Agent.start(opts) do
      {:ok, agent} ->
        case Nex.Agent.prompt(agent, message) do
          {:ok, response, _agent} ->
            {:ok, response}

          {:error, reason, _agent} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
