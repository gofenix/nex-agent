defmodule Nex.Agent.Tasks do
  @moduledoc false

  alias Nex.Agent.{Audit, Cron, Workspace}

  @tasks_file "tasks.json"

  @spec add(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def add(attrs, opts \\ []) when is_map(attrs) do
    title = Map.get(attrs, "title") || Map.get(attrs, :title)

    if is_binary(title) and String.trim(title) != "" do
      now = now_iso()

      task =
        %{
          "id" => generate_id(),
          "title" => String.trim(title),
          "status" =>
            normalize_status(Map.get(attrs, "status") || Map.get(attrs, :status) || "open"),
          "due_at" => normalize_datetime(Map.get(attrs, "due_at") || Map.get(attrs, :due_at)),
          "follow_up_at" =>
            normalize_datetime(Map.get(attrs, "follow_up_at") || Map.get(attrs, :follow_up_at)),
          "source" => Map.get(attrs, "source") || Map.get(attrs, :source) || "chat_message",
          "project" => blank_to_nil(Map.get(attrs, "project") || Map.get(attrs, :project)),
          "summary" => blank_to_nil(Map.get(attrs, "summary") || Map.get(attrs, :summary)),
          "channel" => blank_to_nil(Keyword.get(opts, :channel)),
          "chat_id" => blank_to_nil(Keyword.get(opts, :chat_id)),
          "created_at" => now,
          "updated_at" => now,
          "job_ids" => %{}
        }
        |> sync_jobs(opts)

      save_tasks([task | load_tasks(tasks_file(opts))], opts)
      Audit.append("task.add", task, opts)
      {:ok, task}
    else
      {:error, "title is required"}
    end
  end

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    filters = Keyword.get(opts, :filters, %{})

    tasks_file(opts)
    |> load_tasks()
    |> Enum.filter(fn task ->
      match_filter?(task, "status", filters) and match_filter?(task, "project", filters)
    end)
    |> Enum.sort_by(&{status_rank(&1["status"]), &1["due_at"] || "~", &1["created_at"] || "~"})
  end

  @spec get(String.t(), keyword()) :: map() | nil
  def get(task_id, opts \\ []) do
    tasks_file(opts)
    |> load_tasks()
    |> Enum.find(&(&1["id"] == task_id))
  end

  @spec update(String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def update(task_id, attrs, opts \\ []) when is_binary(task_id) and is_map(attrs) do
    with %{} = task <- get(task_id, opts) do
      updated =
        task
        |> Map.put("title", update_field(task, attrs, "title", &normalize_string/1))
        |> Map.put("status", update_field(task, attrs, "status", &normalize_status/1))
        |> Map.put("due_at", update_field(task, attrs, "due_at", &normalize_datetime/1))
        |> Map.put(
          "follow_up_at",
          update_field(task, attrs, "follow_up_at", &normalize_datetime/1)
        )
        |> Map.put("source", update_field(task, attrs, "source", &normalize_string/1))
        |> Map.put("project", update_field(task, attrs, "project", &blank_to_nil/1))
        |> Map.put("summary", update_field(task, attrs, "summary", &blank_to_nil/1))
        |> Map.put("channel", task["channel"] || blank_to_nil(Keyword.get(opts, :channel)))
        |> Map.put("chat_id", task["chat_id"] || blank_to_nil(Keyword.get(opts, :chat_id)))
        |> Map.put("updated_at", now_iso())
        |> sync_jobs(opts)

      replace_task(updated, opts)
      Audit.append("task.update", updated, opts)
      {:ok, updated}
    else
      nil -> {:error, "Task not found: #{task_id}"}
    end
  end

  @spec complete(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, String.t()}
  def complete(task_id, summary \\ nil, opts \\ []) do
    update(
      task_id,
      %{"status" => "completed", "summary" => summary, "due_at" => nil, "follow_up_at" => nil},
      opts
    )
  end

  @spec snooze(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def snooze(task_id, until_iso, opts \\ []) do
    update(task_id, %{"status" => "snoozed", "due_at" => until_iso}, opts)
  end

  @spec follow_up(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def follow_up(task_id, at_iso, summary \\ nil, opts \\ []) do
    update(task_id, %{"status" => "open", "follow_up_at" => at_iso, "summary" => summary}, opts)
  end

  @spec summary(String.t(), keyword()) :: map()
  def summary(scope, opts \\ []) when scope in ["daily", "weekly", "all"] do
    tasks = list(opts)
    cutoff = scope_cutoff(scope)

    recent =
      if cutoff do
        Enum.filter(tasks, fn task ->
          after_cutoff?(task["updated_at"], cutoff) or after_cutoff?(task["created_at"], cutoff)
        end)
      else
        tasks
      end

    upcoming =
      tasks
      |> Enum.filter(&(&1["status"] in ["open", "snoozed"]))
      |> Enum.filter(&(is_binary(&1["due_at"]) or is_binary(&1["follow_up_at"])))
      |> Enum.take(10)

    %{
      "scope" => scope,
      "open" => Enum.count(tasks, &(&1["status"] in ["open", "snoozed"])),
      "completed" => Enum.count(tasks, &(&1["status"] == "completed")),
      "recent" => recent,
      "upcoming" => upcoming,
      "text" =>
        Nex.Agent.PersonalSummary.build(scope, tasks: tasks, workspace: Workspace.root(opts))
    }
  end

  @spec task_file(keyword()) :: String.t()
  def task_file(opts \\ []) do
    tasks_file(opts)
  end

  defp replace_task(updated, opts) do
    tasks =
      load_tasks(tasks_file(opts))
      |> Enum.map(fn task -> if task["id"] == updated["id"], do: updated, else: task end)

    save_tasks(tasks, opts)
  end

  defp sync_jobs(task, opts) do
    task =
      task
      |> sync_due_job(opts)
      |> sync_follow_up_job(opts)

    if task["status"] in ["completed", "cancelled"] do
      remove_job_if_present("task_due:#{task["id"]}", task["job_ids"]["due"], opts)
      remove_job_if_present("task_follow_up:#{task["id"]}", task["job_ids"]["follow_up"], opts)
      put_in(task, ["job_ids"], %{})
    else
      task
    end
  end

  defp sync_due_job(task, opts) do
    if blank?(task["due_at"]) do
      remove_job_if_present("task_due:#{task["id"]}", task["job_ids"]["due"], opts)
      put_in(task, ["job_ids", "due"], nil)
    else
      job_id = ensure_job("task_due:#{task["id"]}", task["due_at"], due_message(task), task, opts)
      put_in(task, ["job_ids", "due"], job_id)
    end
  end

  defp sync_follow_up_job(task, opts) do
    if blank?(task["follow_up_at"]) do
      remove_job_if_present("task_follow_up:#{task["id"]}", task["job_ids"]["follow_up"], opts)
      put_in(task, ["job_ids", "follow_up"], nil)
    else
      job_id =
        ensure_job(
          "task_follow_up:#{task["id"]}",
          task["follow_up_at"],
          follow_up_message(task),
          task,
          opts
        )

      put_in(task, ["job_ids", "follow_up"], job_id)
    end
  end

  defp ensure_job(name, at_iso, message, task, opts) do
    workspace_opts = workspace_opts(opts)
    remove_job_if_present(name, nil, opts)

    with true <- Process.whereis(Nex.Agent.Cron) != nil,
         {:ok, timestamp} <- unix_timestamp(at_iso) do
      case Cron.add_job(
             %{
               name: name,
               message: message,
               channel: task["channel"],
               chat_id: task["chat_id"],
               schedule: %{type: :at, timestamp: timestamp},
               delete_after_run: true
             },
             workspace_opts
           ) do
        {:ok, job} -> job.id
        {:error, _} -> nil
      end
    else
      _ -> nil
    end
  end

  defp remove_job_if_present(name, known_job_id, opts) do
    workspace_opts = workspace_opts(opts)

    cond do
      Process.whereis(Nex.Agent.Cron) == nil ->
        :ok

      is_binary(known_job_id) ->
        _ = Cron.remove_job(known_job_id, workspace_opts)
        :ok

      true ->
        Cron.list_jobs(workspace_opts)
        |> Enum.filter(&(&1.name == name))
        |> Enum.each(fn job -> _ = Cron.remove_job(job.id, workspace_opts) end)
    end
  end

  defp due_message(task) do
    """
    Task reminder: #{task["title"]}

    Task ID: #{task["id"]}
    #{summary_line(task)}
    Review the task, update the task state if needed, and send the user a concise reminder only if there is something actionable.
    """
    |> String.trim()
  end

  defp follow_up_message(task) do
    """
    Follow up on task: #{task["title"]}

    Task ID: #{task["id"]}
    #{summary_line(task)}
    Check whether the user needs a follow-up, update the task if needed, and send a concise nudge if it is genuinely useful.
    """
    |> String.trim()
  end

  defp summary_line(task) do
    case task["summary"] do
      summary when is_binary(summary) and summary != "" -> "Summary: #{summary}"
      _ -> "Summary: (none yet)"
    end
  end

  defp tasks_file(opts) do
    Path.join(Workspace.tasks_dir(opts), @tasks_file)
  end

  defp workspace_opts(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> []
      workspace -> [workspace: workspace]
    end
  end

  defp load_tasks(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, tasks} when is_list(tasks) -> tasks
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp save_tasks(tasks, opts) do
    Workspace.ensure!(opts)
    File.write!(tasks_file(opts), Jason.encode!(tasks, pretty: true))
  end

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(""), do: nil

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _ -> value
    end
  end

  defp normalize_datetime(value), do: to_string(value)

  defp normalize_string(nil), do: nil
  defp normalize_string(value), do: to_string(value)

  defp normalize_status(status) when status in ["open", "completed", "snoozed", "cancelled"],
    do: status

  defp normalize_status(:open), do: "open"
  defp normalize_status(:completed), do: "completed"
  defp normalize_status(:snoozed), do: "snoozed"
  defp normalize_status(:cancelled), do: "cancelled"
  defp normalize_status(_), do: "open"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: to_string(value)

  defp unix_timestamp(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, DateTime.to_unix(dt)}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp match_filter?(_task, _field, filters) when map_size(filters) == 0, do: true

  defp match_filter?(task, field, filters) do
    case Map.get(filters, field) || Map.get(filters, String.to_atom(field)) do
      nil -> true
      value -> task[field] == value
    end
  end

  defp status_rank("open"), do: 0
  defp status_rank("snoozed"), do: 1
  defp status_rank("completed"), do: 2
  defp status_rank("cancelled"), do: 3
  defp status_rank(_), do: 9

  defp scope_cutoff("daily"), do: DateTime.utc_now() |> DateTime.add(-86_400, :second)
  defp scope_cutoff("weekly"), do: DateTime.utc_now() |> DateTime.add(-7 * 86_400, :second)
  defp scope_cutoff("all"), do: nil

  defp after_cutoff?(nil, _cutoff), do: false

  defp after_cutoff?(iso, cutoff) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.compare(dt, cutoff) != :lt
      _ -> false
    end
  end

  defp generate_id do
    "task_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp blank?(value), do: value in [nil, ""]

  defp attr_present?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, String.to_atom(key))
  end

  defp attr_value(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, String.to_atom(key)))
  end

  defp update_field(task, attrs, key, transform) do
    if attr_present?(attrs, key) do
      transform.(attr_value(attrs, key))
    else
      task[key]
    end
  end
end
