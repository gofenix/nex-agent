defmodule Nex.SkillRuntime.LegacyMigrator do
  @moduledoc false

  alias Nex.Agent.Workspace
  alias Nex.SkillRuntime.{Manifest, Package, Store}

  @migration_version 1

  @spec migrate(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def migrate(opts \\ []) do
    Store.ensure!(opts)

    runtime_packages = runtime_packages(opts)

    existing_by_origin =
      Map.new(runtime_packages, fn package ->
        {get_in(package.source || %{}, ["original_path"]), package}
      end)

    existing_names =
      runtime_packages
      |> Enum.map(& &1.name)
      |> MapSet.new()

    {report, _names} =
      collect_sources(opts)
      |> Enum.reduce({[], existing_names}, fn source, {report, names} ->
        cond do
          Map.has_key?(existing_by_origin, source.original_path) ->
            {[report_row(source, "skipped", "already_migrated") | report], names}

          MapSet.member?(names, source.name) ->
            {[report_row(source, "skipped", "name_conflict") | report], names}

          true ->
            case migrate_source(source, opts) do
              {:ok, target_path} ->
                row = source |> report_row("migrated", nil) |> Map.put("target_path", target_path)
                {[row | report], MapSet.put(names, source.name)}

              {:error, reason} ->
                {[report_row(source, "skipped", reason) | report], names}
            end
        end
      end)

    report =
      report
      |> Enum.reverse()

    Store.write_migration_report(report, opts)
    {:ok, report}
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp runtime_packages(opts) do
    skills_dir = Workspace.skills_dir(opts)

    if File.dir?(skills_dir) do
      skills_dir
      |> File.ls!()
      |> Enum.filter(&(String.starts_with?(&1, "rt__") or String.starts_with?(&1, "gh__")))
      |> Enum.flat_map(fn name ->
        case Package.from_dir(Path.join(skills_dir, name)) do
          {:ok, package} -> [package]
          _ -> []
        end
      end)
    else
      []
    end
  end

  defp collect_sources(opts) do
    [
      {Workspace.skills_dir(opts), "legacy_local", 0},
      {Path.join(Keyword.get(opts, :project_root, File.cwd!()), ".nex/skills"), "legacy_repo", 1}
    ]
    |> Enum.flat_map(fn {root, source_type, priority} ->
      scan_root(root, source_type, priority)
    end)
    |> Enum.sort_by(fn source ->
      {source.priority, String.downcase(source.name), source.original_path}
    end)
  end

  defp scan_root(root, _source_type, _priority) when not is_binary(root), do: []

  defp scan_root(root, source_type, priority) do
    if File.dir?(root) do
      root
      |> File.ls!()
      |> Enum.reject(&(String.starts_with?(&1, "rt__") or String.starts_with?(&1, "gh__")))
      |> Enum.flat_map(fn name ->
        path = Path.join(root, name)

        cond do
          File.regular?(path) and String.ends_with?(name, ".md") ->
            source_from_file(path, source_type, priority)

          File.dir?(path) and File.exists?(Path.join(path, "SKILL.md")) ->
            source_from_dir(path, source_type, priority)

          true ->
            []
        end
      end)
    else
      []
    end
  end

  defp source_from_file(path, source_type, priority) do
    case Manifest.load(path) do
      {:ok, manifest} ->
        [
          %{
            name: manifest.name,
            source_type: source_type,
            original_path: Path.expand(path),
            priority: priority,
            entry_type: :file
          }
        ]

      _ ->
        []
    end
  end

  defp source_from_dir(path, source_type, priority) do
    case Package.from_dir(path) do
      {:ok, package} ->
        [
          %{
            name: package.name,
            source_type: source_type,
            original_path: Path.expand(path),
            priority: priority,
            entry_type: :dir
          }
        ]

      _ ->
        []
    end
  end

  defp migrate_source(source, opts) do
    target_path = target_path_for(source, opts)

    if File.exists?(target_path) do
      {:error, "target_exists"}
    else
      File.mkdir_p!(Path.dirname(target_path))

      case source.entry_type do
        :file ->
          File.mkdir_p!(target_path)
          File.cp!(source.original_path, Path.join(target_path, "SKILL.md"))

        :dir ->
          File.cp_r!(source.original_path, target_path)
      end

      write_skill_id!(target_path, source)
      write_source!(target_path, source)
      {:ok, target_path}
    end
  end

  defp target_path_for(source, opts) do
    Path.join(Workspace.skills_dir(opts), "rt__#{Package.slugify(source.name)}")
  end

  defp write_skill_id!(target_path, source) do
    skill_id =
      "skill_" <>
        (:crypto.hash(:sha256, "#{source.source_type}:#{source.original_path}")
         |> Base.encode16(case: :lower)
         |> String.slice(0, 16))

    File.write!(Path.join(target_path, ".skill_id"), skill_id <> "\n")
  end

  defp write_source!(target_path, source) do
    payload = %{
      "source_type" => source.source_type,
      "original_path" => source.original_path,
      "migrated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "migration_version" => @migration_version,
      "active" => true
    }

    File.write!(Path.join(target_path, "source.json"), Jason.encode!(payload, pretty: true))
  end

  defp report_row(source, status, reason) do
    %{
      "name" => source.name,
      "source_type" => source.source_type,
      "original_path" => source.original_path,
      "status" => status,
      "reason" => reason
    }
  end
end
