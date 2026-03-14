defmodule Nex.Agent.Cron do
  @moduledoc """
  Scheduled jobs - supports `every`, `at`, and `cron` scheduling modes, intelligent timers, delivery context, and job state tracking.
  """

  use GenServer
  require Logger

  @jobs_file Path.join(System.get_env("HOME", "~"), ".nex/agent/cron/jobs.json")

  defstruct [
    :id,
    :name,
    :schedule,
    :message,
    :enabled,
    # delivery context
    :channel,
    :chat_id,
    # one-shot auto cleanup
    :delete_after_run,
    # job state
    :last_run,
    :next_run,
    :last_status,
    :last_error,
    # timestamps
    :created_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          schedule: map(),
          message: String.t(),
          enabled: boolean(),
          channel: String.t() | nil,
          chat_id: String.t() | nil,
          delete_after_run: boolean(),
          last_run: integer() | nil,
          next_run: integer() | nil,
          last_status: String.t() | nil,
          last_error: String.t() | nil,
          created_at: integer() | nil,
          updated_at: integer() | nil
        }

  # ── Client API ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  @spec add_job(map()) :: {:ok, t()} | {:error, term()}
  def add_job(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:add_job, attrs})
  end

  @spec remove_job(String.t()) :: :ok | {:error, :not_found}
  def remove_job(job_id) do
    GenServer.call(__MODULE__, {:remove_job, job_id})
  end

  @spec list_jobs() :: [t()]
  def list_jobs do
    GenServer.call(__MODULE__, :list_jobs)
  end

  @spec enable_job(String.t(), boolean()) :: {:ok, t()} | {:error, :not_found}
  def enable_job(job_id, enabled) do
    GenServer.call(__MODULE__, {:enable_job, job_id, enabled})
  end

  @spec run_job(String.t()) :: {:ok, t()} | {:error, :not_found}
  def run_job(job_id) do
    GenServer.call(__MODULE__, {:run_job, job_id})
  end

  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── GenServer callbacks ──

  @impl true
  def init(_) do
    jobs = load_jobs()
    timer_ref = arm_timer(jobs)
    {:ok, %{jobs: jobs, timer_ref: timer_ref}}
  end

  @impl true
  def handle_call({:add_job, attrs}, _from, state) do
    now = System.system_time(:second)

    schedule = Map.get(attrs, :schedule)
    delete_after_run = Map.get(attrs, :delete_after_run, schedule[:type] == :at)

    job = %__MODULE__{
      id: generate_id(),
      name: Map.get(attrs, :name, "unnamed"),
      schedule: schedule,
      message: Map.get(attrs, :message),
      enabled: true,
      channel: Map.get(attrs, :channel),
      chat_id: Map.get(attrs, :chat_id),
      delete_after_run: delete_after_run,
      last_run: nil,
      next_run: calculate_next_run(schedule, now),
      last_status: nil,
      last_error: nil,
      created_at: now,
      updated_at: now
    }

    jobs = [job | state.jobs]
    save_jobs(jobs)
    {:reply, {:ok, job}, rearm(%{state | jobs: jobs})}
  end

  @impl true
  def handle_call({:remove_job, job_id}, _from, state) do
    case Enum.split_with(state.jobs, &(&1.id == job_id)) do
      {[_], remaining} ->
        save_jobs(remaining)
        {:reply, :ok, rearm(%{state | jobs: remaining})}

      {[], _} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_jobs, _from, state) do
    {:reply, state.jobs, state}
  end

  @impl true
  def handle_call({:enable_job, job_id, enabled}, _from, state) do
    now = System.system_time(:second)

    case Enum.split_with(state.jobs, &(&1.id == job_id)) do
      {[job], remaining} ->
        next = if enabled, do: calculate_next_run(job.schedule, now), else: job.next_run
        updated = %{job | enabled: enabled, next_run: next, updated_at: now}
        jobs = [updated | remaining]
        save_jobs(jobs)
        {:reply, {:ok, updated}, rearm(%{state | jobs: jobs})}

      {[], _} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:run_job, job_id}, _from, state) do
    case Enum.find(state.jobs, &(&1.id == job_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      job ->
        execute_job(job)
        now = System.system_time(:second)
        {jobs, deleted?} = update_job_after_run(state.jobs, job.id, now, :ok, nil)
        save_jobs(jobs)

        updated = Enum.find(jobs, &(&1.id == job_id))

        if deleted? do
          {:reply, {:ok, %{job | last_status: "ok", last_run: now}}, rearm(%{state | jobs: jobs})}
        else
          {:reply, {:ok, updated}, rearm(%{state | jobs: jobs})}
        end
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    now = System.system_time(:second)

    next_wakeup =
      state.jobs
      |> Enum.filter(&(&1.enabled and &1.next_run != nil))
      |> Enum.map(& &1.next_run)
      |> Enum.min(fn -> nil end)

    status = %{
      total: length(state.jobs),
      enabled: Enum.count(state.jobs, & &1.enabled),
      disabled: Enum.count(state.jobs, &(not &1.enabled)),
      next_wakeup: next_wakeup,
      next_wakeup_in: if(next_wakeup, do: max(0, next_wakeup - now), else: nil)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.system_time(:second)

    {to_run, _rest} =
      Enum.split_with(state.jobs, fn job ->
        job.enabled and job.next_run != nil and job.next_run <= now
      end)

    run_ids = MapSet.new(to_run, & &1.id)
    Enum.each(to_run, &execute_job/1)

    jobs =
      state.jobs
      |> Enum.reduce([], fn job, acc ->
        if MapSet.member?(run_ids, job.id) do
          {updated, _deleted?} = update_job_after_run_single(job, now, :ok, nil)
          if updated, do: [updated | acc], else: acc
        else
          [job | acc]
        end
      end)
      |> Enum.reverse()

    save_jobs(jobs)
    {:noreply, rearm(%{state | jobs: jobs})}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Smart Timer ──

  defp arm_timer(jobs) do
    now = System.system_time(:second)

    next =
      jobs
      |> Enum.filter(&(&1.enabled and &1.next_run != nil))
      |> Enum.map(& &1.next_run)
      |> Enum.min(fn -> nil end)

    case next do
      nil ->
        nil

      ts ->
        # Cap at ~49 days to avoid Process.send_after overflow (max 2^32-1 ms)
        delay_ms = min(max((ts - now) * 1000, 0), 4_294_967_295)
        Process.send_after(self(), :tick, delay_ms)
    end
  end

  defp rearm(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: arm_timer(state.jobs)}
  end

  # ── Job Execution ──

  defp execute_job(job) do
    Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
      content =
        job.message <>
          "\n\n[CRON] This is a scheduled task. Use the `message` tool to deliver results to the user. " <>
          "If there is nothing meaningful to report, do NOT call message — just reply with a short text and it will be silently discarded."

      payload = %{
        channel: job.channel || "cron",
        chat_id: job.chat_id || "",
        content: content,
        metadata: %{"_from_cron" => true, "job_id" => job.id, "job_name" => job.name}
      }

      Nex.Agent.Bus.publish(:inbound, payload)
    end)
  end

  defp update_job_after_run(jobs, job_id, now, status, error) do
    Enum.reduce(jobs, {[], false}, fn job, {acc, deleted?} ->
      if job.id == job_id do
        {updated, was_deleted?} = update_job_after_run_single(job, now, status, error)
        if updated, do: {[updated | acc], deleted?}, else: {acc, was_deleted?}
      else
        {[job | acc], deleted?}
      end
    end)
    |> then(fn {jobs, deleted?} -> {Enum.reverse(jobs), deleted?} end)
  end

  defp update_job_after_run_single(job, now, status, error) do
    status_str = to_string(status)

    cond do
      # at type + delete_after_run → remove
      job.schedule[:type] == :at and job.delete_after_run ->
        {nil, true}

      # at type + not delete → disable
      job.schedule[:type] == :at ->
        {%{
           job
           | last_run: now,
             next_run: nil,
             last_status: status_str,
             last_error: error,
             enabled: false,
             updated_at: now
         }, false}

      # recurring → compute next
      true ->
        {%{
           job
           | last_run: now,
             next_run: calculate_next_run(job.schedule, now),
             last_status: status_str,
             last_error: error,
             updated_at: now
         }, false}
    end
  end

  # ── Schedule Calculation ──

  defp calculate_next_run(%{type: :every, seconds: seconds}, now) do
    now + seconds
  end

  defp calculate_next_run(%{type: :at, timestamp: timestamp}, now) do
    if timestamp > now, do: timestamp, else: nil
  end

  defp calculate_next_run(%{type: :cron, expr: expr}, now) do
    case parse_cron_expr(expr) do
      {:ok, fields} -> next_cron_time(fields, now)
      {:error, _} -> nil
    end
  end

  defp calculate_next_run(_, _now), do: nil

  # ── Cron Expression Parser ──
  # Standard 5-field: minute hour day_of_month month day_of_week
  # Supports: *, specific numbers, comma lists, ranges (1-5), steps (*/15)

  defp parse_cron_expr(expr) when is_binary(expr) do
    parts = String.split(expr, ~r/\s+/, trim: true)

    if length(parts) != 5 do
      {:error, "cron expression must have exactly 5 fields: minute hour dom month dow"}
    else
      [minute, hour, dom, month, dow] = parts

      with {:ok, min_set} <- parse_field(minute, 0, 59),
           {:ok, hour_set} <- parse_field(hour, 0, 23),
           {:ok, dom_set} <- parse_field(dom, 1, 31),
           {:ok, month_set} <- parse_field(month, 1, 12),
           {:ok, dow_set} <- parse_field(dow, 0, 6) do
        {:ok, %{minute: min_set, hour: hour_set, dom: dom_set, month: month_set, dow: dow_set}}
      end
    end
  end

  defp parse_field("*", min, max) do
    {:ok, MapSet.new(min..max)}
  end

  defp parse_field(field, min, max) do
    parts = String.split(field, ",")

    Enum.reduce_while(parts, {:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case parse_field_part(part, min, max) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_field_part(part, min, max) do
    cond do
      # */step
      String.starts_with?(part, "*/") ->
        case Integer.parse(String.trim_leading(part, "*/")) do
          {step, ""} when step > 0 ->
            values = for v <- min..max, rem(v - min, step) == 0, do: v
            {:ok, MapSet.new(values)}

          _ ->
            {:error, "invalid step: #{part}"}
        end

      # range with step: 1-5/2
      String.contains?(part, "/") ->
        [range_part, step_str] = String.split(part, "/", parts: 2)

        with {step, ""} when step > 0 <- Integer.parse(step_str),
             {:ok, range_start, range_end} <- parse_range(range_part, min, max) do
          values = for v <- range_start..range_end, rem(v - range_start, step) == 0, do: v
          {:ok, MapSet.new(values)}
        else
          _ -> {:error, "invalid range/step: #{part}"}
        end

      # range: 1-5
      String.contains?(part, "-") ->
        case parse_range(part, min, max) do
          {:ok, range_start, range_end} -> {:ok, MapSet.new(range_start..range_end)}
          err -> err
        end

      # single number
      true ->
        case Integer.parse(part) do
          {n, ""} when n >= min and n <= max -> {:ok, MapSet.new([n])}
          _ -> {:error, "invalid value: #{part}"}
        end
    end
  end

  defp parse_range(range_str, min, max) do
    case String.split(range_str, "-", parts: 2) do
      [a_str, b_str] ->
        with {a, ""} <- Integer.parse(a_str),
             {b, ""} <- Integer.parse(b_str) do
          if a >= min and b <= max and a <= b do
            {:ok, a, b}
          else
            {:error, "range out of bounds: #{range_str}"}
          end
        else
          _ -> {:error, "invalid range: #{range_str}"}
        end

      _ ->
        {:error, "invalid range: #{range_str}"}
    end
  end

  @doc false
  def next_cron_time(fields, now) do
    # Start from the next minute
    {{y, mo, d}, {h, m, _s}} = :calendar.system_time_to_universal_time(now, :second)
    find_next(fields, {y, mo, d, h, m + 1}, 0)
  end

  # Search up to ~4 years worth of minutes to find next match
  defp find_next(_fields, _dt, attempts) when attempts > 525_960, do: nil

  defp find_next(fields, {y, mo, d, h, m}, attempts) do
    # Normalize overflows
    {y, mo, d, h, m} = normalize_datetime(y, mo, d, h, m)

    dow = day_of_week(y, mo, d)

    if MapSet.member?(fields.month, mo) and
         MapSet.member?(fields.dom, d) and
         MapSet.member?(fields.dow, dow) and
         MapSet.member?(fields.hour, h) and
         MapSet.member?(fields.minute, m) and
         d <= days_in_month(y, mo) do
      :calendar.datetime_to_gregorian_seconds({{y, mo, d}, {h, m, 0}}) -
        :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
    else
      # Try to skip intelligently
      cond do
        not MapSet.member?(fields.month, mo) ->
          # Jump to next valid month
          find_next(fields, {y, mo + 1, 1, 0, 0}, attempts + 1)

        d > days_in_month(y, mo) ->
          find_next(fields, {y, mo + 1, 1, 0, 0}, attempts + 1)

        not MapSet.member?(fields.dom, d) or not MapSet.member?(fields.dow, dow) ->
          find_next(fields, {y, mo, d + 1, 0, 0}, attempts + 1)

        not MapSet.member?(fields.hour, h) ->
          find_next(fields, {y, mo, d, h + 1, 0}, attempts + 1)

        true ->
          find_next(fields, {y, mo, d, h, m + 1}, attempts + 1)
      end
    end
  end

  defp normalize_datetime(y, mo, d, h, m) do
    {h, m} =
      if m > 59 do
        {h + div(m, 60), rem(m, 60)}
      else
        {h, m}
      end

    {d, h} =
      if h > 23 do
        {d + div(h, 24), rem(h, 24)}
      else
        {d, h}
      end

    {y, mo, d} = normalize_date(y, mo, d)
    {y, mo, d, h, m}
  end

  defp normalize_date(y, mo, d) when mo > 12 do
    normalize_date(y + div(mo - 1, 12), rem(mo - 1, 12) + 1, d)
  end

  defp normalize_date(y, mo, d) do
    max_d = days_in_month(y, mo)

    if d > max_d do
      normalize_date(y, mo + 1, d - max_d)
    else
      {y, mo, d}
    end
  end

  defp days_in_month(y, 2) do
    if rem(y, 4) == 0 and (rem(y, 100) != 0 or rem(y, 400) == 0), do: 29, else: 28
  end

  defp days_in_month(_, m) when m in [4, 6, 9, 11], do: 30
  defp days_in_month(_, _), do: 31

  # 0=Sunday, 1=Monday, ... 6=Saturday
  defp day_of_week(y, m, d) do
    :calendar.day_of_the_week(y, m, d) |> rem(7)
  end

  # ── Persistence ──

  defp load_jobs do
    if File.exists?(@jobs_file) do
      case File.read!(@jobs_file) |> Jason.decode() do
        {:ok, jobs} when is_list(jobs) ->
          Enum.map(jobs, &deserialize_job/1)

        _ ->
          []
      end
    else
      []
    end
  end

  defp deserialize_job(j) do
    schedule = deserialize_schedule(j["schedule"])

    %__MODULE__{
      id: j["id"],
      name: j["name"],
      schedule: schedule,
      message: j["message"],
      enabled: j["enabled"],
      channel: j["channel"],
      chat_id: j["chat_id"],
      delete_after_run: j["delete_after_run"] || false,
      last_run: j["last_run"],
      next_run: j["next_run"],
      last_status: j["last_status"],
      last_error: j["last_error"],
      created_at: j["created_at"],
      updated_at: j["updated_at"]
    }
  end

  defp deserialize_schedule(%{"type" => "every", "seconds" => s}), do: %{type: :every, seconds: s}
  defp deserialize_schedule(%{"type" => "at", "timestamp" => ts}), do: %{type: :at, timestamp: ts}
  defp deserialize_schedule(%{"type" => "cron", "expr" => expr}), do: %{type: :cron, expr: expr}
  defp deserialize_schedule(other), do: other

  defp save_jobs(jobs) do
    data = Enum.map(jobs, &serialize_job/1)
    encoded = Jason.encode!(data, pretty: true)

    dir = Path.dirname(@jobs_file)
    File.mkdir_p!(dir)
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    tmp_path = @jobs_file <> ".tmp.#{suffix}"

    case File.write(tmp_path, encoded) do
      :ok ->
        case File.rename(tmp_path, @jobs_file) do
          :ok -> :ok
          {:error, reason} -> {:error, "Failed to rename jobs file: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to write jobs file: #{reason}"}
    end
  end

  defp serialize_job(j) do
    %{
      "id" => j.id,
      "name" => j.name,
      "schedule" => serialize_schedule(j.schedule),
      "message" => j.message,
      "enabled" => j.enabled,
      "channel" => j.channel,
      "chat_id" => j.chat_id,
      "delete_after_run" => j.delete_after_run,
      "last_run" => j.last_run,
      "next_run" => j.next_run,
      "last_status" => j.last_status,
      "last_error" => j.last_error,
      "created_at" => j.created_at,
      "updated_at" => j.updated_at
    }
  end

  defp serialize_schedule(%{type: :every, seconds: s}), do: %{"type" => "every", "seconds" => s}
  defp serialize_schedule(%{type: :at, timestamp: ts}), do: %{"type" => "at", "timestamp" => ts}
  defp serialize_schedule(%{type: :cron, expr: expr}), do: %{"type" => "cron", "expr" => expr}
  defp serialize_schedule(other), do: other

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
