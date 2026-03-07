defmodule Nex.Agent.MessageBus do
  @moduledoc """
  Async message queue for decoupled channel-agent communication.
  Mirrors nanobot's bus/queue.py.
  """

  use GenServer
  require Logger

  @type inbound_message :: %{
          required(:channel) => String.t(),
          required(:chat_id) => String.t(),
          required(:content) => String.t(),
          optional(:sender_id) => String.t(),
          optional(:media) => [String.t()],
          optional(:metadata) => map()
        }

  @type outbound_message :: %{
          required(:channel) => String.t(),
          required(:chat_id) => String.t(),
          required(:content) => String.t(),
          optional(:metadata) => map()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    {:ok, %{inbound: [], outbound: []}}
  end

  @doc """
  Publish inbound message from channel to agent.
  """
  @spec publish_inbound(inbound_message()) :: :ok
  def publish_inbound(msg) do
    GenServer.cast(__MODULE__, {:publish_inbound, msg})
  end

  @doc """
  Consume next inbound message (blocks until available).
  """
  @spec consume_inbound(timeout()) :: inbound_message() | nil
  def consume_inbound(timeout \\ 5000) do
    GenServer.call(__MODULE__, {:consume_inbound}, timeout)
  end

  @doc """
  Publish outbound message from agent to channel.
  """
  @spec publish_outbound(outbound_message()) :: :ok
  def publish_outbound(msg) do
    GenServer.cast(__MODULE__, {:publish_outbound, msg})
  end

  @doc """
  Consume next outbound message.
  """
  @spec consume_outbound(timeout()) :: outbound_message() | nil
  def consume_outbound(timeout \\ 5000) do
    GenServer.call(__MODULE__, {:consume_outbound}, timeout)
  end

  @impl true
  def handle_cast({:publish_inbound, msg}, state) do
    {:noreply, %{state | inbound: state.inbound ++ [msg]}}
  end

  @impl true
  def handle_cast({:publish_outbound, msg}, state) do
    {:noreply, %{state | outbound: state.outbound ++ [msg]}}
  end

  @impl true
  def handle_call({:consume_inbound}, from, %{inbound: []} = state) do
    Logger.debug("[MessageBus] Waiting for inbound message")
    {:noreply, %{state | inbound: [from | state.inbound]}}
  end

  @impl true
  def handle_call({:consume_inbound}, _from, %{inbound: [msg | rest]} = state) do
    {:reply, msg, %{state | inbound: rest}}
  end

  @impl true
  def handle_call({:consume_outbound}, from, %{outbound: []} = state) do
    Logger.debug("[MessageBus] Waiting for outbound message")
    {:noreply, %{state | outbound: [from | state.outbound]}}
  end

  @impl true
  def handle_call({:consume_outbound}, _from, %{outbound: [msg | rest]} = state) do
    {:reply, msg, %{state | outbound: rest}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end
end
