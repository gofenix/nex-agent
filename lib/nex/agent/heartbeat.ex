defmodule Nex.Agent.Heartbeat do
  @moduledoc """
  Heartbeat Service — periodic agent maintenance, user-defined tasks, and health monitoring.

  Built-in maintenance (once per day):
  - Session GC: delete sessions older than 30 days
  - Memory log archive: archive daily logs older than 60 days
  - Code upgrade cleanup: keep only latest 10 versions per module

  User-defined tasks from HEARTBEAT.md:
  - `every:` interval-based tasks
  - `cron:` cron-expression tasks

  Health checks: verify critical services are alive each tick.
  """

  use GenServer
  require Logger

  alias Nex.Agent.CodeUpgrade

  # 30 minutes
  @default_interval 30 * 60
  @maintenance_cooldown_seconds 86_400
  @session_max_age_days 30
  @log_archive_age_days 60
  @code_upgrade_versions_to_keep 10
  @max_history 50

  defstruct [
    :interval,
    :enabled,
    :workspace,
    :running,
    last_executions: %{},
    last_maintenance: nil,
    last_weekly_evolution: nil,
    maintenance_running: false,
    weekly_evolution_running: false,
    execution_history: []
  ]

  @type t :: %__MODULE__{
          interval: integer(),
          enabled: boolean(),
          workspace: String.t(),
          running: boolean(),
          last_executions: %{String.t() => integer()},
          last_maintenance: integer() | nil,
          last_weekly_evolution: integer() | nil,
          maintenance_running: boolean(),
          weekly_evolution_running: boolean(),
          execution_history: list()
        }

  # ── Client API ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    interval = Keyword.get(opts, :interval, @default_interval)
    enabled = Keyword.get(opts, :enabled, true)

    workspace =
      Keyword.get(
        opts,
        :workspace,
        Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")
      )

    state = %__MODULE__{
      interval: interval,
      enabled: enabled,
      workspace: workspace,
      running: false
    }

    GenServer.start_link(__MODULE__, state, name: name)
  end

  @spec start() :: :ok | {:error, :disabled}
  def start do
    GenServer.call(__MODULE__, :start)
  end

  @spec stop() :: :ok
  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:start, _from, %{enabled: false} = state) do
    {:reply, {:error, :disabled}, state}
  end

  @impl true
  def handle_call(:start, _from, state) do
    schedule_tick(state)
    {:reply, :ok, %{state | running: true}}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    {:reply, :ok, %{state | running: false}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    health = check_services_health()

    status = %{
      enabled: state.enabled,
      running: state.running,
      interval: state.interval,
      last_maintenance: state.last_maintenance,
      last_weekly_evolution: state.last_weekly_evolution,
      last_executions: state.last_executions,
      recent_history: Enum.take(state.execution_history, 10),
      services_health: health
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:tick, %{running: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = execute_heartbeat(state)
    schedule_tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:maintenance_done, results}, state) do
    now = System.system_time(:second)

    history =
      Enum.map(results, fn {task, result} ->
        {to_string(task), now, result}
      end)

    {:noreply,
     %{
       state
       | last_maintenance: now,
         maintenance_running: false,
         execution_history: (history ++ state.execution_history) |> Enum.take(@max_history)
     }}
  end

  @impl true
  def handle_info({:weekly_evolution_done, completed_at, result}, state) do
    history =
      [
        {"evolution", completed_at, %{trigger: "scheduled_weekly", result: result}}
        | state.execution_history
      ]
      |> Enum.take(@max_history)

    case result do
      {:ok, _applied} ->
        {:noreply,
         %{
           state
           | last_weekly_evolution: completed_at,
             weekly_evolution_running: false,
             execution_history: history
         }}

      {:error, _reason} ->
        {:noreply, %{state | weekly_evolution_running: false, execution_history: history}}
    end
  end

  # ── Scheduling ──

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, state.interval * 1000)
  end

  # ── Heartbeat Execution ──

  defp execute_heartbeat(state) do
    now = System.system_time(:second)

    # 1. Built-in maintenance (once per day)
    state = maybe_run_maintenance(state, now)

    # 2. Weekly evolution (deep analysis)
    state = maybe_run_weekly_evolution(state, now)

    # 3. User-defined tasks from HEARTBEAT.md
    state = run_heartbeat_tasks(state, now)

    # 4. Health checks
    health = check_services_health()
    dead = Enum.filter(health, fn {_svc, alive} -> not alive end) |> Enum.map(&elem(&1, 0))

    if dead != [] do
      Logger.warning("[Heartbeat] Dead services detected: #{inspect(dead)}")
    end

    state
  end

  # ── Built-in Maintenance ──

  defp maybe_run_maintenance(state, now) do
    if state.maintenance_running do
      state
    else
      if state.last_maintenance && now - state.last_maintenance < @maintenance_cooldown_seconds do
        state
      else
        Logger.info("[Heartbeat] Running daily maintenance (async)...")
        heartbeat = self()
        workspace = state.workspace

        Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
          results = [
            {:session_gc, run_session_gc(workspace)},
            {:log_archive, run_log_archive(workspace)},
            {:code_upgrade_cleanup, run_code_upgrade_cleanup()},
            {:evolution, %{trigger: "scheduled_daily", result: run_daily_evolution(workspace)}}
          ]

          send(heartbeat, {:maintenance_done, results})
        end)

        %{state | maintenance_running: true}
      end
    end
  end

  defp run_session_gc(workspace) do
    sessions_dir = Path.join(workspace, "sessions")

    if File.exists?(sessions_dir) do
      cutoff = Date.utc_today() |> Date.add(-@session_max_age_days)

      File.ls!(sessions_dir)
      |> Enum.each(fn file ->
        path = Path.join(sessions_dir, file)

        case File.stat(path) do
          {:ok, %{mtime: mtime}} ->
            file_date = mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_date()

            if Date.compare(file_date, cutoff) == :lt do
              File.rm_rf!(path)
              Logger.info("[Heartbeat] GC'd old session: #{file}")
            end

          _ ->
            :ok
        end
      end)

      :ok
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("[Heartbeat] Session GC error: #{Exception.message(e)}")
      :error
  end

  defp run_log_archive(workspace) do
    memory_dir = Path.join(workspace, "memory")
    archive_dir = Path.join(memory_dir, "archive")

    if File.exists?(memory_dir) do
      cutoff = Date.utc_today() |> Date.add(-@log_archive_age_days)

      File.ls!(memory_dir)
      |> Enum.filter(&Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, &1))
      |> Enum.each(fn date_str ->
        case Date.from_iso8601(date_str) do
          {:ok, date} ->
            if Date.compare(date, cutoff) == :lt do
              date_dir = Path.join(memory_dir, date_str)
              log_file = Path.join(date_dir, "log.md")

              if File.exists?(log_file) do
                # Archive to YYYY-MM.md
                archive_name = String.slice(date_str, 0..6) <> ".md"
                archive_path = Path.join(archive_dir, archive_name)
                File.mkdir_p!(archive_dir)

                content = File.read!(log_file)
                header = "\n\n# #{date_str}\n\n"
                File.write!(archive_path, header <> content, [:append])

                # Remove original
                File.rm_rf!(date_dir)
                Logger.info("[Heartbeat] Archived log: #{date_str}")
              end
            end

          _ ->
            :ok
        end
      end)

      :ok
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("[Heartbeat] Log archive error: #{Exception.message(e)}")
      :error
  end

  defp run_code_upgrade_cleanup do
    versions_root = CodeUpgrade.versions_root()

    if File.exists?(versions_root) do
      versions_root
      |> File.ls!()
      |> Enum.each(fn module_name ->
        module_dir = Path.join(versions_root, module_name)

        if File.dir?(module_dir) do
          module_dir
          |> version_files()
          |> Enum.drop(@code_upgrade_versions_to_keep)
          |> Enum.each(fn path ->
            File.rm_rf!(path)
            Logger.info("[Heartbeat] Removed old code upgrade version: #{Path.basename(path)}")
          end)
        end
      end)
    end

    :ok
  rescue
    e ->
      Logger.warning("[Heartbeat] Code upgrade cleanup error: #{Exception.message(e)}")
      :error
  end

  defp version_files(module_dir) do
    module_dir
    |> File.ls!()
    |> Enum.reject(&(&1 == "backup.ex"))
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.map(&Path.join(module_dir, &1))
    |> Enum.sort_by(
      fn path ->
        case File.stat(path) do
          {:ok, stat} -> stat.mtime
          _ -> {{0, 0, 0}, {0, 0, 0}}
        end
      end,
      :desc
    )
  end

  # ── Evolution ──

  defp run_daily_evolution(workspace) do
    run_evolution(:scheduled_daily, workspace)
  end

  @weekly_evolution_cooldown 7 * 86_400

  defp maybe_run_weekly_evolution(state, now) do
    last_weekly = state.last_weekly_evolution || 0

    cond do
      state.weekly_evolution_running ->
        state

      now - last_weekly >= @weekly_evolution_cooldown ->
        Logger.info("[Heartbeat] Running scheduled deep evolution (async)...")

        heartbeat = self()
        workspace = state.workspace

        Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
          result = run_evolution(:scheduled_weekly, workspace)
          send(heartbeat, {:weekly_evolution_done, now, result})
        end)

        %{state | weekly_evolution_running: true}

      true ->
        state
    end
  end

  defp run_evolution(trigger, workspace) do
    case Nex.Agent.Evolution.run_evolution_cycle(workspace: workspace, trigger: trigger) do
      {:ok, _applied} = ok ->
        ok

      {:error, reason} = error ->
        Logger.warning("[Heartbeat] #{trigger} evolution failed: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.warning("[Heartbeat] #{trigger} evolution error: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # ── HEARTBEAT.md Tasks ──

  defp run_heartbeat_tasks(state, now) do
    heartbeat_file = Path.join(state.workspace, "HEARTBEAT.md")

    if File.exists?(heartbeat_file) do
      tasks = parse_heartbeat_file(heartbeat_file)

      Enum.reduce(tasks, state, fn task, acc ->
        if should_run_task?(task, acc.last_executions, now) do
          run_user_task(task, acc, now)
        else
          acc
        end
      end)
    else
      state
    end
  end

  defp parse_heartbeat_file(path) do
    File.read!(path)
    |> String.split(~r/(?=^## )/m, trim: true)
    |> Enum.map(&parse_heartbeat_section/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_heartbeat_section(section) do
    lines = String.split(section, "\n", trim: true)

    case lines do
      ["## " <> name | rest] ->
        props =
          Enum.reduce(rest, %{}, fn line, acc ->
            case String.split(line, ":", parts: 2) do
              [key, value] ->
                Map.put(acc, String.trim(key) |> String.downcase(), String.trim(value))

              _ ->
                acc
            end
          end)

        message = Map.get(props, "message")

        cond do
          is_nil(message) or message == "" ->
            nil

          Map.has_key?(props, "every") ->
            seconds = parse_duration(props["every"])

            if seconds > 0,
              do: %{name: String.trim(name), type: :every, seconds: seconds, message: message},
              else: nil

          Map.has_key?(props, "cron") ->
            %{name: String.trim(name), type: :cron, expr: props["cron"], message: message}

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp parse_duration(str) do
    str = String.trim(str) |> String.downcase()

    cond do
      String.ends_with?(str, "h") ->
        case Integer.parse(String.trim_trailing(str, "h")) do
          {n, ""} -> n * 3600
          _ -> 0
        end

      String.ends_with?(str, "m") ->
        case Integer.parse(String.trim_trailing(str, "m")) do
          {n, ""} -> n * 60
          _ -> 0
        end

      String.ends_with?(str, "s") ->
        case Integer.parse(String.trim_trailing(str, "s")) do
          {n, ""} -> n
          _ -> 0
        end

      true ->
        case Integer.parse(str) do
          {n, ""} -> n
          _ -> 0
        end
    end
  end

  defp should_run_task?(%{type: :every, seconds: seconds, name: name}, last_executions, now) do
    case Map.get(last_executions, name) do
      nil -> true
      last -> now - last >= seconds
    end
  end

  defp should_run_task?(%{type: :cron, expr: expr, name: name}, last_executions, now) do
    last = Map.get(last_executions, name, 0)
    # Simple check: if more than 60s since last run and cron matches current minute
    if now - last < 60, do: false, else: cron_matches_now?(expr, now)
  end

  defp cron_matches_now?(expr, now) do
    parts = String.split(expr, ~r/\s+/, trim: true)

    if length(parts) != 5 do
      false
    else
      {{_y, mo, d}, {h, m, _s}} = :calendar.system_time_to_universal_time(now, :second)
      {date, _time} = :calendar.system_time_to_universal_time(now, :second)
      dow = :calendar.day_of_the_week(date) |> rem(7)

      [min_f, hour_f, dom_f, month_f, dow_f] = parts

      field_matches?(min_f, m, 0, 59) and
        field_matches?(hour_f, h, 0, 23) and
        field_matches?(dom_f, d, 1, 31) and
        field_matches?(month_f, mo, 1, 12) and
        field_matches?(dow_f, dow, 0, 6)
    end
  rescue
    _ -> false
  end

  defp field_matches?("*", _val, _min, _max), do: true

  defp field_matches?(field, val, min, _max) do
    cond do
      # */step
      String.starts_with?(field, "*/") ->
        case Integer.parse(String.trim_leading(field, "*/")) do
          {step, ""} when step > 0 -> rem(val - min, step) == 0
          _ -> false
        end

      # comma list: 1,3,5
      String.contains?(field, ",") ->
        field
        |> String.split(",")
        |> Enum.any?(fn part ->
          case Integer.parse(String.trim(part)) do
            {n, ""} -> n == val
            _ -> false
          end
        end)

      # range: 1-5
      String.contains?(field, "-") ->
        case String.split(field, "-", parts: 2) do
          [a_str, b_str] ->
            with {a, ""} <- Integer.parse(a_str),
                 {b, ""} <- Integer.parse(b_str) do
              val >= a and val <= b
            else
              _ -> false
            end

          _ ->
            false
        end

      # single number
      true ->
        case Integer.parse(field) do
          {n, ""} -> n == val
          _ -> false
        end
    end
  end

  defp run_user_task(task, state, now) do
    Logger.info("[Heartbeat] Running task: #{task.name}")

    Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
      payload = %{
        channel: "heartbeat",
        chat_id: "",
        content: task.message,
        metadata: %{"_from_heartbeat" => true, "task_name" => task.name}
      }

      Nex.Agent.Bus.publish(:inbound, payload)
    end)

    entry = {task.name, now, :ok}

    %{
      state
      | last_executions: Map.put(state.last_executions, task.name, now),
        execution_history: [entry | state.execution_history] |> Enum.take(@max_history)
    }
  end

  # ── Health Checks ──

  defp check_services_health do
    %{
      bus: Process.whereis(Nex.Agent.Bus) != nil,
      tool_registry: Process.whereis(Nex.Agent.Tool.Registry) != nil,
      inbound_worker: Process.whereis(Nex.Agent.InboundWorker) != nil,
      cron: Process.whereis(Nex.Agent.Cron) != nil
    }
  end
end
