defmodule Nex.Agent.Tool.ExecutorDispatch do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Executor

  def name, do: "executor_dispatch"

  def description,
    do:
      "Dispatch a coding task to Codex CLI, Claude Code CLI, or the local agent execution route."

  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          task: %{type: "string", description: "Task to delegate"},
          executor: %{
            type: "string",
            enum: ["codex_cli", "claude_code_cli", "nex_local"],
            description: "Preferred executor"
          },
          cwd: %{type: "string", description: "Working directory for the executor"},
          project: %{type: "string", description: "Optional project name"},
          summary: %{
            type: "string",
            description: "Optional short summary for audit/status output"
          }
        },
        required: ["task"]
      }
    }
  end

  def execute(%{"task" => _task} = args, ctx) do
    args =
      args
      |> Map.put_new("cwd", Map.get(ctx, :cwd) || Map.get(ctx, "cwd") || File.cwd!())
      |> maybe_put_new("project", Map.get(ctx, :project) || Map.get(ctx, "project"))

    Executor.dispatch(args, workspace_opts(ctx))
  end

  def execute(_args, _ctx), do: {:error, "task is required"}

  defp workspace_opts(ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")
    if workspace, do: [workspace: workspace], else: []
  end

  defp maybe_put_new(map, _key, nil), do: map

  defp maybe_put_new(map, key, value) do
    Map.put_new(map, key, value)
  end
end
