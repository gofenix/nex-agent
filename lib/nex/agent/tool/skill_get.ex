defmodule Nex.Agent.Tool.SkillGet do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.SkillRuntime

  def name, do: "skill_get"

  def description,
    do: "Load a runtime skill package by skill_id or source_id with progressive disclosure."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          skill_id: %{type: "string", description: "Local runtime skill_id to load"},
          source_id: %{type: "string", description: "Trusted catalog source_id to load or import"}
        }
      }
    }
  end

  def execute(args, ctx) do
    with :ok <- ensure_runtime_enabled(ctx),
         {:ok, identifier} <- get_identifier(args),
         {:ok, payload} <- SkillRuntime.get(identifier, runtime_opts(ctx)) do
      {:ok, payload}
    end
  end

  defp get_identifier(%{"skill_id" => skill_id}) when is_binary(skill_id) and skill_id != "",
    do: {:ok, skill_id}

  defp get_identifier(%{"source_id" => source_id}) when is_binary(source_id) and source_id != "",
    do: {:ok, source_id}

  defp get_identifier(_args), do: {:error, "skill_id or source_id is required"}

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
