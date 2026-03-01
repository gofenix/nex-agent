defmodule Nex.Agent.Bus do
  @moduledoc """
  消息总线 - 简单的 PubSub 实现
  """

  use GenServer

  defstruct [:subscribers]

  @type t :: %__MODULE__{
          subscribers: %{term() => [pid()]}
        }

  @doc """
  启动 Bus
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{subscribers: %{}}, name: name)
  end

  @doc """
  订阅主题
  """
  @spec subscribe(term(), pid()) :: :ok
  def subscribe(topic \\ :default, pid \\ nil) do
    pid = pid || self()
    GenServer.call(__MODULE__, {:subscribe, topic, pid})
  end

  @doc """
  取消订阅
  """
  @spec unsubscribe(term(), pid()) :: :ok
  def unsubscribe(topic \\ :default, pid \\ nil) do
    pid = pid || self()
    GenServer.call(__MODULE__, {:unsubscribe, topic, pid})
  end

  @doc """
  发布消息
  """
  @spec publish(term(), term()) :: :ok
  def publish(topic \\ :default, message) do
    GenServer.cast(__MODULE__, {:publish, topic, message})
  end

  @doc """
  同步发布消息（等待所有订阅者处理完成）
  """
  @spec publish_sync(term(), term()) :: :ok
  def publish_sync(topic \\ :default, message) do
    GenServer.call(__MODULE__, {:publish_sync, topic, message})
  end

  @doc """
  获取订阅者列表
  """
  @spec subscribers(term()) :: [pid()]
  def subscribers(topic \\ :default) do
    GenServer.call(__MODULE__, {:subscribers, topic})
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, topic, pid}, _from, state) do
    subscribers = Map.get(state.subscribers, topic, [])

    if pid in subscribers do
      {:reply, :ok, state}
    else
      Process.monitor(pid)
      new_subscribers = [pid | subscribers]
      new_state = %{state | subscribers: Map.put(state.subscribers, topic, new_subscribers)}
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, topic, pid}, _from, state) do
    subscribers = Map.get(state.subscribers, topic, [])
    new_subscribers = List.delete(subscribers, pid)
    new_state = %{state | subscribers: Map.put(state.subscribers, topic, new_subscribers)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:publish_sync, topic, message}, _from, state) do
    subscribers = Map.get(state.subscribers, topic, [])

    Enum.each(subscribers, fn pid ->
      send(pid, {:bus_message, topic, message})
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:subscribers, topic}, _from, state) do
    {:reply, Map.get(state.subscribers, topic, []), state}
  end

  @impl true
  def handle_cast({:publish, topic, message}, state) do
    subscribers = Map.get(state.subscribers, topic, [])

    Enum.each(subscribers, fn pid ->
      send(pid, {:bus_message, topic, message})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers =
      state.subscribers
      |> Enum.map(fn {topic, subscribers} ->
        {topic, List.delete(subscribers, pid)}
      end)
      |> Map.new()

    {:noreply, %{state | subscribers: new_subscribers}}
  end
end
