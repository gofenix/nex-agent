defmodule Nex.Agent.SessionManager do
  @moduledoc """
  Session manager - get/create/load/save sessions.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Session, Workspace}

  @consolidation_flag "consolidation_in_progress"
  @consolidation_started_at_flag "consolidation_started_at"
  @consolidation_timeout_sec 900

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    {:ok, %{cache: %{}}}
  end

  @doc """
  Get existing session or create new one.
  """
  @spec get_or_create(String.t(), keyword()) :: Session.t()
  def get_or_create(key, opts \\ []) do
    GenServer.call(__MODULE__, {:get_or_create, key, opts})
  end

  @doc """
  Get session from cache (without loading from disk).
  """
  @spec get(String.t(), keyword()) :: Session.t() | nil
  def get(key, opts \\ []) do
    GenServer.call(__MODULE__, {:get, key, opts})
  end

  @doc """
  Save session to disk and update cache.
  """
  @spec save(Session.t(), keyword()) :: :ok
  def save(%Session{} = session, opts \\ []) do
    GenServer.cast(__MODULE__, {:save, session, opts})
  end

  @doc """
  Invalidate cache for a session.
  """
  @spec invalidate(String.t(), keyword()) :: :ok
  def invalidate(key, opts \\ []) do
    GenServer.cast(__MODULE__, {:invalidate, key, opts})
  end

  @doc """
  Atomically mark a session as running memory consolidation.
  """
  @spec start_consolidation(String.t(), non_neg_integer(), keyword()) ::
          {:ok, Session.t(), non_neg_integer()} | :already_running | :below_threshold
  def start_consolidation(key, min_unconsolidated, opts \\ []) do
    GenServer.call(__MODULE__, {:start_consolidation, key, min_unconsolidated, opts})
  end

  @doc """
  Clear the memory consolidation in-progress flag and persist the session.
  """
  @spec finish_consolidation(Session.t(), keyword()) :: :ok
  def finish_consolidation(%Session{} = session, opts \\ []) do
    GenServer.cast(__MODULE__, {:finish_consolidation, session, opts})
  end

  @doc """
  Clear the memory consolidation in-progress flag without changing session content.
  """
  @spec cancel_consolidation(String.t(), keyword()) :: :ok
  def cancel_consolidation(key, opts \\ []) do
    GenServer.cast(__MODULE__, {:cancel_consolidation, key, opts})
  end

  @doc """
  List all sessions.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @impl true
  def handle_call({:get_or_create, key, opts}, _from, %{cache: cache} = state) do
    cache_key = cache_key(key, opts)

    session =
      case Map.get(cache, cache_key) do
        nil ->
          case Session.load(key, opts) do
            nil -> Session.new(key)
            s -> s
          end

        s ->
          s
      end

    {:reply, session, %{state | cache: Map.put(cache, cache_key, session)}}
  end

  def handle_call({:get, key, opts}, _from, %{cache: cache} = state) do
    {:reply, Map.get(cache, cache_key(key, opts)), state}
  end

  def handle_call(
        {:start_consolidation, key, min_unconsolidated, opts},
        _from,
        %{cache: cache} = state
      ) do
    cache_key = cache_key(key, opts)

    session =
      cache
      |> load_session(key, opts)
      |> maybe_recover_stale_consolidation(opts)

    unconsolidated = length(session.messages) - session.last_consolidated

    cond do
      consolidation_in_progress?(session) ->
        {:reply, :already_running, %{state | cache: Map.put(cache, cache_key, session)}}

      unconsolidated < min_unconsolidated ->
        {:reply, :below_threshold, %{state | cache: Map.put(cache, cache_key, session)}}

      true ->
        marked_session = put_consolidation_flag(session, true)
        Session.save(marked_session, opts)

        {:reply, {:ok, marked_session, unconsolidated},
         %{state | cache: Map.put(cache, cache_key, marked_session)}}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    sessions =
      Path.wildcard(Path.join([Session.sessions_dir(opts), "*", "messages.jsonl"]))
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
  def handle_cast({:save, session, opts}, %{cache: cache} = state) do
    cache_key = cache_key(session.key, opts)

    merged_session =
      cache
      |> Map.get(cache_key, Session.load(session.key, opts))
      |> merge_session(session)

    Session.save(merged_session, opts)
    {:noreply, %{state | cache: Map.put(cache, cache_key, merged_session)}}
  end

  def handle_cast({:invalidate, key, opts}, %{cache: cache} = state) do
    {:noreply, %{state | cache: Map.delete(cache, cache_key(key, opts))}}
  end

  def handle_cast({:finish_consolidation, session, opts}, %{cache: cache} = state) do
    cache_key = cache_key(session.key, opts)

    merged_session =
      cache
      |> Map.get(cache_key, Session.load(session.key, opts))
      |> merge_session(session)
      |> put_consolidation_flag(false)

    Session.save(merged_session, opts)
    {:noreply, %{state | cache: Map.put(cache, cache_key, merged_session)}}
  end

  def handle_cast({:cancel_consolidation, key, opts}, %{cache: cache} = state) do
    cache_key = cache_key(key, opts)

    session =
      cache
      |> load_session(key, opts)
      |> put_consolidation_flag(false)

    Session.save(session, opts)
    {:noreply, %{state | cache: Map.put(cache, cache_key, session)}}
  end

  defp load_session(cache, key, opts) do
    case Map.get(cache, cache_key(key, opts)) do
      nil -> Session.load(key, opts) || Session.new(key)
      session -> session
    end
  end

  defp consolidation_in_progress?(%Session{} = session) do
    Map.get(session.metadata || %{}, @consolidation_flag, false) == true
  end

  defp maybe_recover_stale_consolidation(%Session{} = session, opts) do
    if consolidation_in_progress?(session) and stale_consolidation?(session) do
      Logger.warning(
        "[SessionManager] Recovering stale memory consolidation flag for #{session.key}"
      )

      session
      |> put_consolidation_flag(false)
      |> then(fn cleared ->
        Session.save(cleared, opts)
        cleared
      end)
    else
      session
    end
  end

  defp stale_consolidation?(%Session{} = session) do
    metadata = session.metadata || %{}

    case Map.get(metadata, @consolidation_started_at_flag) do
      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, started_at, _offset} ->
            DateTime.diff(DateTime.utc_now(), started_at, :second) >= @consolidation_timeout_sec

          _ ->
            true
        end

      _ ->
        true
    end
  end

  defp put_consolidation_flag(%Session{} = session, enabled) do
    metadata =
      if enabled do
        session.metadata
        |> Kernel.||(%{})
        |> Map.put(@consolidation_flag, true)
        |> Map.put(@consolidation_started_at_flag, DateTime.utc_now() |> DateTime.to_iso8601())
      else
        session.metadata
        |> Kernel.||(%{})
        |> Map.delete(@consolidation_flag)
        |> Map.delete(@consolidation_started_at_flag)
      end

    %{session | metadata: metadata}
  end

  defp merge_session(nil, %Session{} = incoming), do: incoming

  defp merge_session(%Session{} = existing, %Session{} = incoming) do
    messages =
      if length(incoming.messages) >= length(existing.messages) do
        incoming.messages
      else
        existing.messages
      end

    updated_at =
      case DateTime.compare(existing.updated_at, incoming.updated_at) do
        :gt -> existing.updated_at
        _ -> incoming.updated_at
      end

    %Session{
      incoming
      | created_at: existing.created_at,
        updated_at: updated_at,
        metadata: incoming.metadata || existing.metadata || %{},
        messages: messages,
        last_consolidated:
          min(max(existing.last_consolidated, incoming.last_consolidated), length(messages))
    }
  end

  defp cache_key(key, opts) do
    {Workspace.root(opts) |> Path.expand(), key}
  end
end
