defmodule Nex.Agent.Tool.SkillImport do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.SkillRuntime

  def name, do: "skill_import"

  def description,
    do: "Import a package skill from the trusted GitHub catalog into the workspace."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          source_id: %{type: "string", description: "Catalog source_id to import"},
          repo: %{type: "string", description: "Optional GitHub repo in owner/repo format"},
          commit_sha: %{type: "string", description: "Immutable source commit SHA"},
          path: %{type: "string", description: "Directory path within the repo"}
        }
      }
    }
  end

  def execute(%{"source_id" => source_id}, ctx) when is_binary(source_id) and source_id != "" do
    with :ok <- ensure_runtime_enabled(ctx),
         {:ok, package} <- SkillRuntime.import(source_id, runtime_opts(ctx)) do
      {:ok, format_package(package)}
    end
  end

  def execute(%{"repo" => repo, "commit_sha" => commit_sha, "path" => path} = args, ctx)
      when is_binary(repo) and is_binary(commit_sha) and is_binary(path) do
    with :ok <- ensure_runtime_enabled(ctx),
         {:ok, package} <- SkillRuntime.import(args, runtime_opts(ctx)) do
      {:ok, format_package(package)}
    end
  end

  def execute(_args, _ctx), do: {:error, "source_id or repo/commit_sha/path is required"}

  defp format_package(package) do
    %{
      "skill_id" => package.skill_id,
      "name" => package.name,
      "execution_mode" => package.execution_mode,
      "tool_name" => package.tool_name,
      "available" => package.available,
      "root_path" => package.root_path
    }
  end

  defp runtime_opts(ctx) do
    [
      workspace: Map.get(ctx, :workspace),
      project_root: Map.get(ctx, :cwd, File.cwd!()),
      skill_runtime: Map.get(ctx, :skill_runtime, %{})
    ]
  end

  defp ensure_runtime_enabled(ctx) do
    if SkillRuntime.enabled?(runtime_opts(ctx)) do
      :ok
    else
      {:error, "SkillRuntime is disabled in config"}
    end
  end
end
