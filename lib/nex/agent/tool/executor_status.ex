defmodule Nex.Agent.Tool.ExecutorStatus do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Executor

  def name, do: "executor_status"
  def description, do: "Inspect configured executors and recent executor runs."
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          executor: %{
            type: "string",
            enum: ["codex_cli", "claude_code_cli", "nex_local"],
            description: "Specific executor to inspect"
          },
          run_id: %{type: "string", description: "Specific run ID to inspect"},
          limit: %{type: "integer", description: "Recent run count"}
        }
      }
    }
  end

  def execute(%{"run_id" => run_id}, ctx) when is_binary(run_id) and run_id != "" do
    case Executor.get_run(run_id, workspace_opts(ctx)) do
      nil -> {:error, "Executor run not found: #{run_id}"}
      run -> {:ok, run}
    end
  end

  def execute(%{"executor" => executor}, ctx)
      when executor in ["codex_cli", "claude_code_cli", "nex_local"] do
    {:ok, Executor.executor_status(executor, workspace_opts(ctx))}
  end

  def execute(args, ctx) do
    limit = Map.get(args, "limit", 20)
    {:ok, Executor.status(workspace_opts(ctx) ++ [limit: limit])}
  end

  defp workspace_opts(ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")
    if workspace, do: [workspace: workspace], else: []
  end
end
