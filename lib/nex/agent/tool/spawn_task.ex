defmodule Nex.Agent.Tool.SpawnTask do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "spawn_task"
  def description, do: "Spawn a background subagent to handle a task independently."
  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          task: %{type: "string", description: "Description of the task to perform"},
          label: %{type: "string", description: "Short label for the task"}
        },
        required: ["task"]
      }
    }
  end

  def execute(%{"task" => task_desc} = args, ctx) do
    label = args["label"]

    spawn_opts = [
      label: label,
      session_key: Map.get(ctx, :session_key),
      provider: Map.get(ctx, :provider),
      model: Map.get(ctx, :model),
      api_key: Map.get(ctx, :api_key),
      base_url: Map.get(ctx, :base_url),
      workspace: Map.get(ctx, :workspace),
      cwd: Map.get(ctx, :cwd),
      project: Map.get(ctx, :project),
      metadata: Map.get(ctx, :metadata, %{}),
      channel: Map.get(ctx, :channel),
      chat_id: Map.get(ctx, :chat_id)
    ]

    if Process.whereis(Nex.Agent.Subagent) do
      {:ok, task_id} = Nex.Agent.Subagent.spawn_task(task_desc, spawn_opts)
      {:ok, "Background task spawned: #{task_id} (#{label || "unlabeled"})"}
    else
      {:error, "Subagent service is not running"}
    end
  end

  def execute(_args, _ctx), do: {:error, "task description is required"}
end
