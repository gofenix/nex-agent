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

  alias Nex.Agent.{Bus, Reflection, Memory}

  @default_reflection_interval 15 * 60 * 1000
  @default_min_results 20
  @max_results_window 200
  @memory_review_interval 24 * 60 * 60 * 1000
  @daily_log_retention_days 30

  defstruct [
    :opts,
    :reflection_timer,
    :memory_review_timer,
    results: [],
    last_reflection_at: nil,
    last_memory_review_at: nil,
    reflection_count: 0,
    auto_apply: false
  ]

  @type t :: %__MODULE__{
          opts: keyword(),
          reflection_timer: reference() | nil,
          memory_review_timer: reference() | nil,
          results: [map()],
          last_reflection_at: DateTime.t() | nil,
          last_memory_review_at: DateTime.t() | nil,
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
    # Self-load config if provider/model/api_key not provided
    opts = maybe_load_config(opts)
    auto_apply = Keyword.get(opts, :auto_apply, false)
    interval = Keyword.get(opts, :reflection_interval, @default_reflection_interval)

    Bus.subscribe(:tool_result)

    state = %__MODULE__{
      opts: opts,
      auto_apply: auto_apply,
      results: [],
      last_reflection_at: nil,
      last_memory_review_at: nil,
      reflection_count: 0
    }

    state = schedule_reflection(state, interval)
    state = schedule_memory_review(state)

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
    memory_sections = Memory.read_memory_sections()
    memory_size = case File.stat(Path.join([System.get_env("HOME", "~"), ".nex", "agent", "workspace", "memory", "MEMORY.md"])) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end

    status = %{
      results_count: length(state.results),
      last_reflection_at: state.last_reflection_at,
      reflection_count: state.reflection_count,
      auto_apply: state.auto_apply,
      memory: %{
        sections: length(memory_sections),
        size_bytes: memory_size,
        last_review_at: state.last_memory_review_at
      }
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
  def handle_info(:memory_review, state) do
    Logger.info("[Harness] Starting memory review cycle")

    Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
      run_memory_review(state.opts)
    end)

    state = %{state | last_memory_review_at: DateTime.utc_now()}
    {:noreply, schedule_memory_review(state)}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp run_reflection(state) do
    if state.results == [] do
      {:error, :no_results, state}
    else
      Logger.info("[Harness] Running reflection on #{length(state.results)} results")

      # Reload config each time to pick up changes
      config = Nex.Agent.Config.load()

      reflection_opts = [
        provider: String.to_atom(config.provider),
        model: config.model,
        api_key: Nex.Agent.Config.get_current_api_key(config),
        base_url: Nex.Agent.Config.get_current_base_url(config),
        auto_apply: state.auto_apply
      ]

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

  defp schedule_memory_review(state) do
    if state.memory_review_timer, do: Process.cancel_timer(state.memory_review_timer)
    timer = Process.send_after(self(), :memory_review, @memory_review_interval)
    %{state | memory_review_timer: timer}
  end

  defp run_memory_review(_opts) do
    # 1. Cleanup old daily logs
    cleanup_old_daily_logs(@daily_log_retention_days)

    # 2. LLM-driven memory review if enough sections
    sections = Memory.read_memory_sections()

    if length(sections) >= 3 do
      review_memory_with_llm(sections)
    else
      Logger.debug("[Harness] Memory review skipped: only #{length(sections)} sections")
    end
  rescue
    e ->
      Logger.warning("[Harness] Memory review failed: #{Exception.message(e)}")
  end

  defp cleanup_old_daily_logs(retention_days) do
    memory_dir = Path.join([System.get_env("HOME", "~"), ".nex", "agent", "workspace", "memory"])
    cutoff = Date.utc_today() |> Date.add(-retention_days)

    if File.exists?(memory_dir) do
      memory_dir
      |> File.ls!()
      |> Enum.filter(&Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, &1))
      |> Enum.filter(fn date_str ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> Date.compare(date, cutoff) == :lt
          _ -> false
        end
      end)
      |> Enum.each(fn date_str ->
        dir = Path.join(memory_dir, date_str)
        File.rm_rf!(dir)
        Logger.info("[Harness] Cleaned up old daily log: #{date_str}")
      end)
    end
  end

  defp review_memory_with_llm(sections) do
    config = Nex.Agent.Config.load()

    sections_text =
      Enum.map_join(sections, "\n\n", fn s ->
        "## #{s.header}\n#{s.content}"
      end)

    messages = [
      %{
        "role" => "system",
        "content" => """
        You are a memory quality reviewer. Analyze the agent's long-term memory sections.
        Call the review_memory tool with pruning suggestions for outdated, redundant, or low-value sections.
        Be conservative — only suggest removing sections that are clearly outdated or duplicated.
        """
      },
      %{
        "role" => "user",
        "content" => "## Current MEMORY.md\n\n#{sections_text}"
      }
    ]

    tools = [
      %{
        "name" => "review_memory",
        "description" => "Submit memory pruning suggestions",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "prune_actions" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "section" => %{"type" => "string", "description" => "Section header to prune"},
                  "action" => %{"type" => "string", "enum" => ["remove"], "description" => "Action to take"},
                  "reason" => %{"type" => "string", "description" => "Why this section should be pruned"}
                },
                "required" => ["section", "action", "reason"]
              }
            }
          },
          "required" => ["prune_actions"]
        }
      }
    ]

    review_opts = [
      provider: String.to_atom(config.provider),
      model: config.model,
      api_key: Nex.Agent.Config.get_current_api_key(config),
      base_url: Nex.Agent.Config.get_current_base_url(config),
      tools: tools,
      tool_choice: tool_choice_for(String.to_atom(config.provider), "review_memory")
    ]

    case Nex.Agent.Runner.call_llm_for_consolidation(messages, review_opts) do
      {:ok, %{"prune_actions" => actions}} when is_list(actions) ->
        Enum.each(actions, fn action ->
          section = action["section"]
          act = action["action"]
          reason = action["reason"] || ""

          Logger.info("[Harness] Memory prune: #{act} '#{section}' — #{reason}")

          Reflection.apply_suggestion(%{
            type: :memory_prune,
            name: section,
            action: act
          })
        end)

      {:ok, _} ->
        Logger.debug("[Harness] Memory review returned no prune actions")

      {:error, reason} ->
        Logger.warning("[Harness] Memory review LLM call failed: #{inspect(reason)}")
    end
  end

  defp tool_choice_for(:anthropic, name),
    do: %{"type" => "tool", "name" => name}

  defp tool_choice_for(_provider, name),
    do: %{"type" => "function", "function" => %{"name" => name}}

  defp maybe_load_config(opts) do
    if Keyword.has_key?(opts, :api_key) do
      opts
    else
      config = Nex.Agent.Config.load()

      Keyword.merge(
        [
          provider: String.to_atom(config.provider),
          model: config.model,
          api_key: Nex.Agent.Config.get_current_api_key(config),
          base_url: Nex.Agent.Config.get_current_base_url(config),
          auto_apply: true
        ],
        opts
      )
    end
  end
end
