defmodule Nex.SkillRuntime.Store do
  @moduledoc false

  alias Nex.Agent.Workspace
  alias Nex.SkillRuntime.{CatalogEntry, ExecutionTrace, Package}

  @spec ensure!(keyword()) :: :ok
  def ensure!(opts \\ []) do
    dirs = [
      runtime_dir(opts),
      index_dir(opts),
      runs_dir(opts),
      cache_dir(opts),
      snapshots_dir(opts),
      Workspace.skills_dir(opts)
    ]

    Enum.each(dirs, &File.mkdir_p!/1)
    :ok
  end

  @spec runtime_dir(keyword()) :: String.t()
  def runtime_dir(opts \\ []), do: resolve_dir(opts, "skill_runtime")

  @spec index_dir(keyword()) :: String.t()
  def index_dir(opts \\ []), do: resolve_dir(opts, "skill_runtime/index")

  @spec runs_dir(keyword()) :: String.t()
  def runs_dir(opts \\ []), do: resolve_dir(opts, "skill_runtime/runs")

  @spec cache_dir(keyword()) :: String.t()
  def cache_dir(opts \\ []), do: resolve_dir(opts, "skill_runtime/cache")

  @spec snapshots_dir(keyword()) :: String.t()
  def snapshots_dir(opts \\ []), do: resolve_dir(opts, "skill_runtime/snapshots")

  @spec skills_index_path(keyword()) :: String.t()
  def skills_index_path(opts \\ []), do: Path.join(index_dir(opts), "skills.jsonl")

  @spec lineage_index_path(keyword()) :: String.t()
  def lineage_index_path(opts \\ []), do: Path.join(index_dir(opts), "lineage.jsonl")

  @spec catalog_index_path(keyword()) :: String.t()
  def catalog_index_path(opts \\ []), do: Path.join(index_dir(opts), "catalog.jsonl")

  @spec migration_report_path(keyword()) :: String.t()
  def migration_report_path(opts \\ []), do: Path.join(index_dir(opts), "migration_report.jsonl")

  @spec load_skill_records(keyword()) :: [map()]
  def load_skill_records(opts \\ []), do: load_jsonl(skills_index_path(opts))

  @spec load_catalog_records(keyword()) :: [CatalogEntry.t()]
  def load_catalog_records(opts \\ []) do
    opts
    |> catalog_index_path()
    |> load_jsonl()
    |> Enum.map(&CatalogEntry.from_map/1)
  end

  @spec upsert_packages([Package.t()], keyword()) :: :ok
  def upsert_packages(packages, opts \\ []) do
    records =
      packages
      |> Enum.map(&Package.to_record/1)

    upsert_jsonl(skills_index_path(opts), records, & &1["skill_id"])
  end

  @spec write_catalog([CatalogEntry.t() | map()], keyword()) :: :ok
  def write_catalog(entries, opts \\ []) do
    rows =
      Enum.map(entries, fn
        %CatalogEntry{} = entry -> CatalogEntry.to_map(entry)
        map when is_map(map) -> map
      end)

    write_jsonl(catalog_index_path(opts), rows)
  end

  @spec append_lineage_event(map(), keyword()) :: :ok
  def append_lineage_event(event, opts \\ []) when is_map(event) do
    append_jsonl(lineage_index_path(opts), event)
  end

  @spec load_lineage_records(keyword()) :: [map()]
  def load_lineage_records(opts \\ []), do: load_jsonl(lineage_index_path(opts))

  @spec write_migration_report([map()], keyword()) :: :ok
  def write_migration_report(rows, opts \\ []) when is_list(rows) do
    write_jsonl(migration_report_path(opts), rows)
  end

  @spec append_run(ExecutionTrace.t() | map(), keyword()) :: {:ok, String.t()}
  def append_run(%ExecutionTrace{} = trace, opts) do
    append_run(Map.from_struct(trace), opts)
  end

  def append_run(trace, opts) when is_map(trace) do
    ensure!(opts)
    run_id = trace[:run_id] || trace["run_id"] || unique_run_id()
    path = Path.join(runs_dir(opts), "#{run_id}.jsonl")
    events = build_run_events(trace, run_id)

    content =
      events
      |> Enum.map(&(Jason.encode!(&1) <> "\n"))
      |> Enum.join()

    File.write!(path, content)
    {:ok, path}
  end

  @spec snapshot_package(Package.t(), keyword()) :: :ok
  def snapshot_package(%Package{} = package, opts \\ []) do
    dest =
      Path.join([
        snapshots_dir(opts),
        package.skill_id,
        Integer.to_string(package.manifest.version || 0)
      ])

    File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))
    File.cp_r!(package.root_path, dest)
    :ok
  end

  defp resolve_dir(opts, default_relative) do
    workspace = Keyword.get(opts, :workspace) || Workspace.root(opts)
    custom = get_in(Keyword.get(opts, :skill_runtime, %{}), [dir_key(default_relative)])

    cond do
      is_binary(custom) and Path.type(custom) == :absolute ->
        custom

      is_binary(custom) and custom != "" ->
        Path.join(workspace, custom)

      true ->
        Path.join(workspace, default_relative)
    end
  end

  defp dir_key("skill_runtime"), do: "runtime_dir"
  defp dir_key("skill_runtime/index"), do: "index_dir"
  defp dir_key("skill_runtime/runs"), do: "trace_dir"
  defp dir_key("skill_runtime/cache"), do: "cache_dir"
  defp dir_key("skill_runtime/snapshots"), do: "snapshots_dir"

  defp build_run_events(trace, run_id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    selected_packages =
      trace[:selected_packages] || trace["selected_packages"] || []

    tool_messages =
      trace[:tool_messages] || trace["tool_messages"] || []

    [
      %{
        "type" => "run_started",
        "run_id" => run_id,
        "prompt" => trace[:prompt] || trace["prompt"],
        "inserted_at" => now
      },
      %{
        "type" => "skills_selected",
        "run_id" => run_id,
        "packages" => selected_packages,
        "inserted_at" => now
      }
    ] ++
      Enum.map(tool_messages, fn message ->
        %{
          "type" => "tool_result",
          "run_id" => run_id,
          "tool" => message["name"] || message[:name],
          "content" => message["content"] || message[:content],
          "tool_call_id" => message["tool_call_id"] || message[:tool_call_id],
          "inserted_at" => now
        }
      end) ++
      [
        %{
          "type" => "run_completed",
          "run_id" => run_id,
          "status" => trace[:status] || trace["status"] || "completed",
          "result" => trace[:result] || trace["result"],
          "inserted_at" => now
        }
      ]
  end

  defp load_jsonl(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
    end
  end

  defp upsert_jsonl(path, rows, key_fun) do
    ensure_parent!(path)

    merged =
      path
      |> load_jsonl()
      |> Enum.reduce(%{}, fn row, acc -> Map.put(acc, key_fun.(row), row) end)
      |> then(fn acc ->
        Enum.reduce(rows, acc, fn row, inner -> Map.put(inner, key_fun.(row), row) end)
      end)
      |> Map.values()
      |> Enum.sort_by(&key_fun.(&1))

    write_jsonl(path, merged)
  end

  defp write_jsonl(path, rows) do
    ensure_parent!(path)

    content =
      rows
      |> Enum.map(&(Jason.encode!(&1) <> "\n"))
      |> Enum.join()

    File.write!(path, content)
  end

  defp append_jsonl(path, row) do
    ensure_parent!(path)
    File.write!(path, Jason.encode!(row) <> "\n", [:append])
    :ok
  end

  defp ensure_parent!(path), do: File.mkdir_p!(Path.dirname(path))

  defp unique_run_id do
    "run_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
