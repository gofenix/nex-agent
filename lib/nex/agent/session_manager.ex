defmodule Nex.Agent.SessionManager do
  @moduledoc """
  Session manager - get/create/load/save sessions.
  Mirrors nanobot's session/manager.py SessionManager class.
  """

  use GenServer

  alias Nex.Agent.Session

  @sessions_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/sessions")

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    File.mkdir_p!(@sessions_dir)
    {:ok, %{cache: %{}}}
  end

  @doc """
  Get existing session or create new one.
  """
  @spec get_or_create(String.t()) :: Session.t()
  def get_or_create(key) do
    GenServer.call(__MODULE__, {:get_or_create, key})
  end

  @doc """
  Get session from cache (without loading from disk).
  """
  @spec get(String.t()) :: Session.t() | nil
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  Save session to disk and update cache.
  """
  @spec save(Session.t()) :: :ok
  def save(%Session{} = session) do
    GenServer.cast(__MODULE__, {:save, session})
  end

  @doc """
  Invalidate cache for a session.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(key) do
    GenServer.cast(__MODULE__, {:invalidate, key})
  end

  @doc """
  List all sessions.
  """
  @spec list() :: [map()]
  def list do
    GenServer.call(__MODULE__, {:list})
  end

  @impl true
  def handle_call({:get_or_create, key}, _from, %{cache: cache} = state) do
    session =
      case Map.get(cache, key) do
        nil ->
          case Session.load(key) do
            nil -> Session.new(key)
            s -> s
          end

        s ->
          s
      end

    {:reply, session, %{state | cache: Map.put(cache, key, session)}}
  end

  def handle_call({:get, key}, _from, %{cache: cache} = state) do
    {:reply, Map.get(cache, key), state}
  end

  def handle_call({:list}, _from, state) do
    sessions =
      Path.wildcard(Path.join([@sessions_dir, "*", "messages.jsonl"]))
      |> Enum.map(fn path ->
        case File.read(path) do
          {:ok, content} ->
            [line | _] = String.split(content, "\n", trim: true)

            case Jason.decode(line) do
              {:ok, %{"_type" => "metadata", "key" => key, "updated_at" => updated_at}} ->
                %{key: key, updated_at: updated_at, path: path}

              _ ->
                nil
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.updated_at, :desc)

    {:reply, sessions, state}
  end

  @impl true
  def handle_cast({:save, session}, %{cache: cache} = state) do
    Session.save(session)
    {:noreply, %{state | cache: Map.put(cache, session.key, session)}}
  end

  def handle_cast({:invalidate, key}, %{cache: cache} = state) do
    {:noreply, %{state | cache: Map.delete(cache, key)}}
  end
end
