defmodule Nex.Agent.Harness do
  @moduledoc """
  Self-evolution harness — the closed loop that ties together:

  1. **Trigger**: Collects tool execution results from the Bus
  2. **Evaluate**: Accumulates results in a rolling window
  3. **Evolve**: Periodically runs LLM-driven Reflection to generate improvements
  4. **Apply**: Auto-applies approved suggestions (skills, soul updates, memory)

  ## Starting

  Started as part of the Gateway supervision tree. Requires Bus to be running.

      Nex.Agent.Harness.start_link(
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        api_key: "..."
      )

  ## Manual trigger

      Nex.Agent.Harness.trigger_reflection()

  ## Configuration

  * `:reflection_interval` - ms between automatic reflections (default 15 min)
  * `:min_results_for_reflection` - minimum tool results before reflecting (default 20)
  * `:auto_apply` - automatically apply suggestions (default false)
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Reflection}

  @default_reflection_interval 15 * 60 * 1000
  @default_min_results 20
  @max_results_window 200

  defstruct [
    :opts,
    :reflection_timer,
    results: [],
    last_reflection_at: nil,
    reflection_count: 0,
    auto_apply: false
  ]

  @type t :: %__MODULE__{
          opts: keyword(),
          reflection_timer: reference() | nil,
          results: [map()],
          last_reflection_at: DateTime.t() | nil,
          reflection_count: non_neg_integer(),
          auto_apply: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually trigger a reflection cycle.
  """
  @spec trigger_reflection() :: {:ok, map()} | {:error, term()}
  def trigger_reflection do
    GenServer.call(__MODULE__, :trigger_reflection, 60_000)
  end

  @doc """
  Get current harness status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Get accumulated tool results.
  """
  @spec results() :: [map()]
  def results do
    GenServer.call(__MODULE__, :results)
  end

  @doc """
  Clear accumulated results.
  """
  @spec clear_results() :: :ok
  def clear_results do
    GenServer.cast(__MODULE__, :clear_results)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    auto_apply = Keyword.get(opts, :auto_apply, false)
    interval = Keyword.get(opts, :reflection_interval, @default_reflection_interval)

    if Process.whereis(Bus) do
      Bus.subscribe(:tool_result)
    end

    state = %__MODULE__{
      opts: opts,
      auto_apply: auto_apply,
      results: [],
      last_reflection_at: nil,
      reflection_count: 0
    }

    state = schedule_reflection(state, interval)

    Logger.info("[Harness] Started auto_apply=#{auto_apply} interval=#{interval}ms")
    {:ok, state}
  end

  @impl true
  def handle_call(:trigger_reflection, _from, state) do
    case run_reflection(state) do
      {:ok, result, new_state} ->
        {:reply, {:ok, result}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      results_count: length(state.results),
      last_reflection_at: state.last_reflection_at,
      reflection_count: state.reflection_count,
      auto_apply: state.auto_apply
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:results, _from, state) do
    {:reply, state.results, state}
  end

  @impl true
  def handle_cast(:clear_results, state) do
    {:noreply, %{state | results: []}}
  end

  @impl true
  def handle_info({:bus_message, :tool_result, payload}, state) when is_map(payload) do
    results = [payload | state.results] |> Enum.take(@max_results_window)
    {:noreply, %{state | results: results}}
  end

  @impl true
  def handle_info(:auto_reflect, state) do
    min_results = Keyword.get(state.opts, :min_results_for_reflection, @default_min_results)
    interval = Keyword.get(state.opts, :reflection_interval, @default_reflection_interval)

    state =
      if length(state.results) >= min_results do
        case run_reflection(state) do
          {:ok, _result, new_state} -> new_state
          {:error, _reason, new_state} -> new_state
        end
      else
        Logger.debug("[Harness] Skipping auto-reflection: #{length(state.results)}/#{min_results} results")
        state
      end

    {:noreply, schedule_reflection(state, interval)}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp run_reflection(state) do
    if state.results == [] do
      {:error, :no_results, state}
    else
      Logger.info("[Harness] Running reflection on #{length(state.results)} results")

      reflection_opts =
        state.opts
        |> Keyword.take([:provider, :model, :api_key, :base_url])
        |> Keyword.put(:auto_apply, state.auto_apply)

      case Reflection.reflect_llm(state.results, reflection_opts) do
        {:ok, result} ->
          Logger.info("[Harness] Reflection complete: #{length(result.suggestions)} suggestions, source=#{result.source}")

          new_state = %{
            state
            | results: [],
              last_reflection_at: DateTime.utc_now(),
              reflection_count: state.reflection_count + 1
          }

          {:ok, result, new_state}
      end
    end
  end

  defp schedule_reflection(state, interval) when is_integer(interval) and interval > 0 do
    if state.reflection_timer, do: Process.cancel_timer(state.reflection_timer)
    timer = Process.send_after(self(), :auto_reflect, interval)
    %{state | reflection_timer: timer}
  end

  defp schedule_reflection(state, _), do: state
end
