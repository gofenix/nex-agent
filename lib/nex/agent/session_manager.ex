defmodule Nex.Agent.SessionManager do
  @moduledoc """
  Session manager - get/create/load/save sessions.
  """

  use GenServer
  require Logger

  alias Nex.Agent.Session

  @sessions_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace/sessions")
  @consolidation_flag "consolidation_in_progress"
  @consolidation_started_at_flag "consolidation_started_at"
  @consolidation_timeout_sec 900

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
  Atomically mark a session as running memory consolidation.
  """
  @spec start_consolidation(String.t(), non_neg_integer()) ::
          {:ok, Session.t(), non_neg_integer()} | :already_running | :below_threshold
  def start_consolidation(key, min_unconsolidated) do
    GenServer.call(__MODULE__, {:start_consolidation, key, min_unconsolidated})
  end

  @doc """
  Clear the memory consolidation in-progress flag and persist the session.
  """
  @spec finish_consolidation(Session.t()) :: :ok
  def finish_consolidation(%Session{} = session) do
    GenServer.cast(__MODULE__, {:finish_consolidation, session})
  end

  @doc """
  Clear the memory consolidation in-progress flag without changing session content.
  """
  @spec cancel_consolidation(String.t()) :: :ok
  def cancel_consolidation(key) do
    GenServer.cast(__MODULE__, {:cancel_consolidation, key})
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

  def handle_call({:start_consolidation, key, min_unconsolidated}, _from, %{cache: cache} = state) do
    session =
      cache
      |> load_session(key)
      |> maybe_recover_stale_consolidation()

    unconsolidated = length(session.messages) - session.last_consolidated

    cond do
      consolidation_in_progress?(session) ->
        {:reply, :already_running, %{state | cache: Map.put(cache, key, session)}}

      unconsolidated < min_unconsolidated ->
        {:reply, :below_threshold, %{state | cache: Map.put(cache, key, session)}}

      true ->
        marked_session = put_consolidation_flag(session, true)
        Session.save(marked_session)

        {:reply, {:ok, marked_session, unconsolidated},
         %{state | cache: Map.put(cache, key, marked_session)}}
    end
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
    merged_session =
      cache
      |> Map.get(session.key, Session.load(session.key))
      |> merge_session(session)

    Session.save(merged_session)
    {:noreply, %{state | cache: Map.put(cache, merged_session.key, merged_session)}}
  end

  def handle_cast({:invalidate, key}, %{cache: cache} = state) do
    {:noreply, %{state | cache: Map.delete(cache, key)}}
  end

  def handle_cast({:finish_consolidation, session}, %{cache: cache} = state) do
    merged_session =
      cache
      |> Map.get(session.key, Session.load(session.key))
      |> merge_session(session)
      |> put_consolidation_flag(false)

    Session.save(merged_session)
    {:noreply, %{state | cache: Map.put(cache, merged_session.key, merged_session)}}
  end

  def handle_cast({:cancel_consolidation, key}, %{cache: cache} = state) do
    session =
      cache
      |> load_session(key)
      |> put_consolidation_flag(false)

    Session.save(session)
    {:noreply, %{state | cache: Map.put(cache, key, session)}}
  end

  defp load_session(cache, key) do
    case Map.get(cache, key) do
      nil -> Session.load(key) || Session.new(key)
      session -> session
    end
  end

  defp consolidation_in_progress?(%Session{} = session) do
    Map.get(session.metadata || %{}, @consolidation_flag, false) == true
  end

  defp maybe_recover_stale_consolidation(%Session{} = session) do
    if consolidation_in_progress?(session) and stale_consolidation?(session) do
      Logger.warning(
        "[SessionManager] Recovering stale memory consolidation flag for #{session.key}"
      )

      session
      |> put_consolidation_flag(false)
      |> then(fn cleared ->
        Session.save(cleared)
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
      cond do
        length(incoming.messages) >= length(existing.messages) ->
          incoming.messages

        true ->
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
end
