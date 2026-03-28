defmodule Nex.Agent.Tool.SkillCapture do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.SkillRuntime

  def name, do: "skill_capture"

  def description do
    "Capture a new local runtime knowledge package in the SKILL layer."
  end

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Runtime skill package name"},
          description: %{type: "string", description: "What reusable workflow this captures"},
          content: %{type: "string", description: "Markdown instructions for the package"},
          references: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional reference files inside the package"
          }
        },
        required: ["name", "description", "content"]
      }
    }
  end

  def execute(
        %{"name" => _name, "description" => _description, "content" => _content} = args,
        ctx
      ) do
    with :ok <- ensure_runtime_enabled(ctx),
         {:ok, package} <- SkillRuntime.capture(args, runtime_opts(ctx)) do
      {:ok,
       %{
         "skill_id" => package.skill_id,
         "name" => package.name,
         "root_path" => package.root_path,
         "execution_mode" => package.execution_mode
       }}
    end
  end

  def execute(_args, _ctx), do: {:error, "name, description, and content are required"}

  defp ensure_runtime_enabled(ctx) do
    if SkillRuntime.enabled?(runtime_opts(ctx)) do
      :ok
    else
      {:error, "SkillRuntime is disabled in config"}
    end
  end

  defp runtime_opts(ctx) do
    [
      workspace: Map.get(ctx, :workspace),
      project_root: Map.get(ctx, :cwd, File.cwd!()),
      skill_runtime: Map.get(ctx, :skill_runtime, %{})
    ]
  end
end
