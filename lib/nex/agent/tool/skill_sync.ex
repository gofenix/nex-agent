defmodule Nex.Agent.Tool.SkillSync do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.SkillRuntime

  def name, do: "skill_sync"
  def description, do: "Refresh the trusted GitHub catalog and update imported package skills."
  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{}
      }
    }
  end

  def execute(_args, ctx) do
    if SkillRuntime.enabled?(runtime_opts(ctx)) do
      SkillRuntime.sync(runtime_opts(ctx))
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
