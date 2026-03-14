defmodule Nex.Agent.Gateway do
  @moduledoc """
  Gateway - Channel orchestrator.

  Manages the lifecycle of channel processes (Telegram, Feishu, Discord, Slack, DingTalk)
  via the ChannelSupervisor (DynamicSupervisor). All infrastructure and worker services
  are managed by the OTP supervision tree in Application.

  Provides start/stop/status/send_message public API.
  """

  use GenServer
  require Logger

  defstruct [:config, :status, :started_at]

  @type status :: :stopped | :starting | :running | :stopping

  @type t :: %__MODULE__{
          config: Nex.Agent.Config.t(),
          status: status(),
          started_at: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Start all channels and heartbeat tick."
  @spec start() :: :ok | {:error, term()}
  def start do
    GenServer.call(__MODULE__, :start, :infinity)
  end

  @doc "Stop all channels and heartbeat tick."
  @spec stop() :: :ok
  def stop do
    GenServer.call(__MODULE__, :stop, :infinity)
  end

  @doc "Get gateway status and service health."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Send a message through the agent."
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

  def handle_call(:start, _from, state) do
    {:reply, {:error, :already_started}, state}
  end

  @impl true
  def handle_call(:stop, _from, %{status: :running} = state) do
    new_state = do_stop(state)
    {:reply, :ok, new_state}
  end

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
        cron: Process.whereis(Nex.Agent.Cron) != nil,
        heartbeat: Process.whereis(Nex.Agent.Heartbeat) != nil,
        tool_registry: Process.whereis(Nex.Agent.Tool.Registry) != nil,
        inbound_worker: Process.whereis(Nex.Agent.InboundWorker) != nil,
        subagent: Process.whereis(Nex.Agent.Subagent) != nil,
        telegram_channel: Process.whereis(Nex.Agent.Channel.Telegram) != nil,
        feishu_channel: Process.whereis(Nex.Agent.Channel.Feishu) != nil,
        discord_channel: Process.whereis(Nex.Agent.Channel.Discord) != nil,
        slack_channel: Process.whereis(Nex.Agent.Channel.Slack) != nil,
        dingtalk_channel: Process.whereis(Nex.Agent.Channel.DingTalk) != nil
      }
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:send_message, message}, _from, %{status: :running} = state) do
    case do_send_message(message) do
      {:ok, response} ->
        {:reply, {:ok, response}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_message, _message}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  # --- Private ---

  defp do_start(state) do
    # Reload config to pick up any changes
    config = Nex.Agent.Config.load()
    state = %{state | config: config}

    if Nex.Agent.Config.valid?(config) do
      # Start heartbeat tick (may not be running if started outside OTP app)
      if Process.whereis(Nex.Agent.Heartbeat) do
        _ = Nex.Agent.Heartbeat.start()
      end

      # Start channels via DynamicSupervisor
      start_channels(config)

      {:ok, %{state | status: :running, started_at: System.system_time(:second)}}
    else
      {:error, :invalid_config}
    end
  end

  defp do_stop(state) do
    # Stop heartbeat tick
    if Process.whereis(Nex.Agent.Heartbeat) do
      _ = Nex.Agent.Heartbeat.stop()
    end

    # Terminate all channel children
    stop_channels()

    %{state | status: :stopped, started_at: nil}
  end

  defp start_channels(config) do
    if Process.whereis(Nex.Agent.ChannelSupervisor) do
      channel_specs(config)
      |> Enum.each(fn spec ->
        case DynamicSupervisor.start_child(Nex.Agent.ChannelSupervisor, spec) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.warning("[Gateway] Failed to start channel: #{inspect(reason)}")
        end
      end)

      # Special: Feishu needs websocket started after the GenServer
      if Nex.Agent.Config.feishu_enabled?(config) and Process.whereis(Nex.Agent.Channel.Feishu) do
        _ = Nex.Agent.Channel.Feishu.start_websocket()
      end
    else
      Logger.warning("[Gateway] ChannelSupervisor not running, skipping channel startup")
    end
  end

  defp stop_channels do
    # Stop Feishu websocket first
    if Process.whereis(Nex.Agent.Channel.Feishu) do
      _ = Nex.Agent.Channel.Feishu.stop_websocket()
    end

    if Process.whereis(Nex.Agent.ChannelSupervisor) do
      DynamicSupervisor.which_children(Nex.Agent.ChannelSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Nex.Agent.ChannelSupervisor, pid)
      end)
    end
  end

  defp channel_specs(config) do
    specs = []

    specs =
      if Nex.Agent.Config.telegram_enabled?(config),
        do: [{Nex.Agent.Channel.Telegram, config: config} | specs],
        else: specs

    specs =
      if Nex.Agent.Config.feishu_enabled?(config),
        do: [{Nex.Agent.Channel.Feishu, config: config} | specs],
        else: specs

    specs =
      if Nex.Agent.Config.discord_enabled?(config),
        do: [{Nex.Agent.Channel.Discord, config: config} | specs],
        else: specs

    specs =
      if Nex.Agent.Config.slack_enabled?(config),
        do: [{Nex.Agent.Channel.Slack, config: config} | specs],
        else: specs

    specs =
      if Nex.Agent.Config.dingtalk_enabled?(config),
        do: [{Nex.Agent.Channel.DingTalk, config: config} | specs],
        else: specs

    specs
  end

  defp do_send_message(message) do
    config = Nex.Agent.Config.load()

    api_key = Nex.Agent.Config.get_current_api_key(config)
    base_url = Nex.Agent.Config.get_current_base_url(config)

    opts = [
      provider: Nex.Agent.Config.provider_to_atom(config.provider),
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
