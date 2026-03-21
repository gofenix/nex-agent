defmodule Nex.Agent.Tool.Task do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Tasks

  def name, do: "task"
  def description, do: "Manage personal tasks, reminders, follow-ups, and summaries."
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["add", "list", "update", "complete", "snooze", "follow_up", "summary"],
            description: "Task action"
          },
          task_id: %{type: "string", description: "Task ID for update/complete/snooze/follow_up"},
          title: %{type: "string", description: "Task title"},
          status: %{type: "string", description: "Task status"},
          due_at: %{type: "string", description: "ISO 8601 due time"},
          follow_up_at: %{type: "string", description: "ISO 8601 follow-up time"},
          source: %{type: "string", description: "Source of the task"},
          project: %{type: "string", description: "Optional project name"},
          summary: %{type: "string", description: "Optional task summary"},
          scope: %{type: "string", enum: ["daily", "weekly", "all"], description: "Summary scope"}
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => "add"} = args, ctx) do
    Tasks.add(task_attrs(args), workspace_opts(ctx))
  end

  def execute(%{"action" => "list"} = args, ctx) do
    filters =
      args
      |> Map.take(["status", "project"])
      |> Enum.into(%{})

    {:ok, %{"tasks" => Tasks.list(workspace_opts(ctx) ++ [filters: filters])}}
  end

  def execute(%{"action" => "update", "task_id" => task_id} = args, ctx) do
    Tasks.update(task_id, task_attrs(args), workspace_opts(ctx))
  end

  def execute(%{"action" => "complete", "task_id" => task_id} = args, ctx) do
    Tasks.complete(task_id, Map.get(args, "summary"), workspace_opts(ctx))
  end

  def execute(%{"action" => "snooze", "task_id" => task_id, "due_at" => due_at}, ctx) do
    Tasks.snooze(task_id, due_at, workspace_opts(ctx))
  end

  def execute(%{"action" => "follow_up", "task_id" => task_id, "follow_up_at" => at} = args, ctx) do
    Tasks.follow_up(task_id, at, Map.get(args, "summary"), workspace_opts(ctx))
  end

  def execute(%{"action" => "summary"} = args, ctx) do
    {:ok, Tasks.summary(Map.get(args, "scope", "all"), workspace_opts(ctx))}
  end

  def execute(%{"action" => action}, _ctx) do
    {:error, "Unsupported task action: #{action}"}
  end

  def execute(_args, _ctx), do: {:error, "action is required"}

  defp task_attrs(args) do
    Map.take(args, ["title", "status", "due_at", "follow_up_at", "source", "project", "summary"])
  end

  defp workspace_opts(ctx) do
    []
    |> maybe_put(:workspace, Map.get(ctx, :workspace) || Map.get(ctx, "workspace"))
    |> maybe_put(:channel, Map.get(ctx, :channel) || Map.get(ctx, "channel"))
    |> maybe_put(:chat_id, Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id"))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
