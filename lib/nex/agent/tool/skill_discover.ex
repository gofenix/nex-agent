defmodule Nex.Agent.Tool.SkillDiscover do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.SkillRuntime

  def name, do: "skill_discover"
  def description, do: "Search local and trusted GitHub package skills managed by the runtime."
  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query for relevant skills"},
          scope: %{
            type: "string",
            enum: ["local", "all"],
            description: "Whether to search local skills only or local plus catalog",
            default: "all"
          },
          limit: %{type: "integer", description: "Maximum number of results", default: 10}
        },
        required: ["query"]
      }
    }
  end

  def execute(%{"query" => query} = args, ctx) when is_binary(query) and query != "" do
    opts = runtime_opts(ctx)

    with :ok <- ensure_runtime_enabled(opts),
         {:ok, hits} <- SkillRuntime.search(query, opts) do
      scope = Map.get(args, "scope", "all")
      limit = Map.get(args, "limit", 10)

      hits =
        hits
        |> maybe_filter_scope(scope)
        |> Enum.take(limit)

      {:ok,
       %{
         "count" => length(hits),
         "hits" => Enum.map(hits, &format_hit/1)
       }}
    end
  end

  def execute(_args, _ctx), do: {:error, "query is required"}

  defp maybe_filter_scope(hits, "local"), do: Enum.filter(hits, &(&1.type == :local))
  defp maybe_filter_scope(hits, _scope), do: hits

  defp format_hit(%{type: :local, package: package, score: score}) do
    %{
      "type" => "local",
      "name" => package.name,
      "skill_id" => package.skill_id,
      "execution_mode" => package.execution_mode,
      "source_type" => package.source_type,
      "active" => package.active,
      "available" => package.available,
      "score" => Float.round(score, 4)
    }
  end

  defp format_hit(%{type: :remote, entry: entry, installed: installed, score: score}) do
    %{
      "type" => "remote",
      "name" => entry.name,
      "source_id" => entry.source_id,
      "repo" => entry.repo,
      "commit_sha" => entry.commit_sha,
      "path" => entry.path,
      "installed" => installed,
      "score" => Float.round(score, 4)
    }
  end

  defp runtime_opts(ctx) do
    [
      workspace: Map.get(ctx, :workspace),
      project_root: Map.get(ctx, :cwd, File.cwd!()),
      skill_runtime: Map.get(ctx, :skill_runtime, %{})
    ]
  end

  defp ensure_runtime_enabled(opts) do
    if SkillRuntime.enabled?(opts) do
      :ok
    else
      {:error, "SkillRuntime is disabled in config"}
    end
  end
end
