defmodule Nex.Agent.Tool.Cron do
  @moduledoc """
  CronTool — allows the agent to manage scheduled tasks autonomously via the LLM.
  Supports seven operations: add, list, remove, enable, disable, run, and status.
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Cron

  def name, do: "cron"
  def description, do: "Manage scheduled tasks: reminders, recurring jobs, and one-time tasks."
  def category, do: :base

  def definition do
    %{
      name: "cron",
      description: """
      Manage scheduled tasks. Create reminders, recurring jobs, and one-time tasks.
      Actions: add, list, remove, enable, disable, run, status.
      For 'add': provide name, message, and one of every_seconds/cron_expr/at.
      """,
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["add", "list", "remove", "enable", "disable", "run", "status"],
            description: "The action to perform"
          },
          name: %{
            type: "string",
            description: "Job name (required for add)"
          },
          message: %{
            type: "string",
            description: "Message to send when job fires (required for add)"
          },
          every_seconds: %{
            type: "integer",
            description: "Interval in seconds for recurring tasks"
          },
          cron_expr: %{
            type: "string",
            description: "Cron expression, e.g. '0 9 * * *' (minute hour dom month dow)"
          },
          at: %{
            type: "string",
            description: "ISO 8601 datetime for one-time execution, e.g. '2026-03-08T10:30:00Z'"
          },
          job_id: %{
            type: "string",
            description: "Job ID (required for remove/enable/disable/run)"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(args, ctx) do
    action = Map.get(args, "action")

    case action do
      "add" -> do_add(args, ctx)
      "list" -> do_list()
      "remove" -> do_remove(args)
      "enable" -> do_enable(args, true)
      "disable" -> do_enable(args, false)
      "run" -> do_run(args)
      "status" -> do_status()
      _ -> {:error, "Unknown action: #{action}. Use: add, list, remove, enable, disable, run, status."}
    end
  end

  # ── Actions ──

  defp do_add(args, ctx) do
    name = Map.get(args, "name")
    message = Map.get(args, "message")

    cond do
      is_nil(message) or message == "" ->
        {:error, "message is required for add"}

      is_nil(name) or name == "" ->
        {:error, "name is required for add"}

      true ->
        channel = Map.get(ctx, :channel) || Map.get(ctx, "channel")
        chat_id = Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id")

        case build_schedule(args) do
          {:ok, schedule} ->
            attrs = %{
              name: name,
              message: message,
              schedule: schedule,
              channel: channel,
              chat_id: to_string(chat_id || "")
            }

            case Cron.add_job(attrs) do
              {:ok, job} ->
                {:ok, %{
                  created: true,
                  job_id: job.id,
                  name: job.name,
                  schedule: format_schedule(job.schedule),
                  next_run: format_timestamp(job.next_run),
                  channel: job.channel,
                  chat_id: job.chat_id,
                  delete_after_run: job.delete_after_run
                }}

              {:error, reason} ->
                {:error, "Failed to add job: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp do_list do
    jobs = Cron.list_jobs()

    formatted =
      Enum.map(jobs, fn j ->
        %{
          id: j.id,
          name: j.name,
          enabled: j.enabled,
          schedule: format_schedule(j.schedule),
          next_run: format_timestamp(j.next_run),
          last_run: format_timestamp(j.last_run),
          last_status: j.last_status,
          channel: j.channel,
          chat_id: j.chat_id
        }
      end)

    {:ok, %{jobs: formatted, total: length(formatted)}}
  end

  defp do_remove(args) do
    case Map.get(args, "job_id") do
      nil -> {:error, "job_id is required for remove"}
      job_id ->
        case Cron.remove_job(job_id) do
          :ok -> {:ok, %{removed: true, job_id: job_id}}
          {:error, :not_found} -> {:error, "Job not found: #{job_id}"}
        end
    end
  end

  defp do_enable(args, enabled) do
    case Map.get(args, "job_id") do
      nil -> {:error, "job_id is required"}
      job_id ->
        case Cron.enable_job(job_id, enabled) do
          {:ok, job} -> {:ok, %{job_id: job.id, enabled: job.enabled}}
          {:error, :not_found} -> {:error, "Job not found: #{job_id}"}
        end
    end
  end

  defp do_run(args) do
    case Map.get(args, "job_id") do
      nil -> {:error, "job_id is required for run"}
      job_id ->
        case Cron.run_job(job_id) do
          {:ok, job} -> {:ok, %{triggered: true, job_id: job.id, name: job.name}}
          {:error, :not_found} -> {:error, "Job not found: #{job_id}"}
        end
    end
  end

  defp do_status do
    case Cron.status() do
      status when is_map(status) ->
        {:ok, Map.put(status, :next_wakeup_formatted, format_timestamp(status.next_wakeup))}
    end
  end

  # ── Helpers ──

  defp build_schedule(args) do
    cond do
      args["every_seconds"] ->
        seconds = to_int(args["every_seconds"])

        if is_integer(seconds) and seconds > 0 do
          {:ok, %{type: :every, seconds: seconds}}
        else
          {:error, "every_seconds must be a positive integer"}
        end

      args["cron_expr"] ->
        expr = args["cron_expr"]
        # Validate cron expression upfront
        case validate_cron_expr(expr) do
          :ok -> {:ok, %{type: :cron, expr: expr}}
          {:error, _} = err -> err
        end

      args["at"] ->
        case parse_iso_datetime(args["at"]) do
          {:ok, timestamp} -> {:ok, %{type: :at, timestamp: timestamp}}
          {:error, _} = err -> err
        end

      true ->
        {:error, "Provide one of: every_seconds, cron_expr, or at"}
    end
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> v
    end
  end
  defp to_int(v) when is_float(v), do: trunc(v)
  defp to_int(v), do: v

  defp validate_cron_expr(expr) do
    parts = String.split(expr, ~r/\s+/, trim: true)

    if length(parts) != 5 do
      {:error, "Cron expression must have 5 fields (minute hour dom month dow), got #{length(parts)}"}
    else
      :ok
    end
  end

  defp parse_iso_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        {:ok, DateTime.to_unix(dt)}

      {:error, _} ->
        # Try NaiveDateTime (no timezone → assume UTC)
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} ->
            {:ok, ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()}

          {:error, _} ->
            {:error, "Invalid datetime format: #{str}. Use ISO 8601 like '2026-03-08T10:30:00Z'"}
        end
    end
  end

  defp format_schedule(%{type: :every, seconds: s}), do: "every #{s}s"
  defp format_schedule(%{type: :cron, expr: e}), do: "cron: #{e}"
  defp format_schedule(%{type: :at, timestamp: ts}), do: "at: #{format_timestamp(ts)}"
  defp format_schedule(_), do: "unknown"

  defp format_timestamp(nil), do: nil

  defp format_timestamp(ts) when is_integer(ts) do
    DateTime.from_unix!(ts) |> DateTime.to_iso8601()
  end
end
