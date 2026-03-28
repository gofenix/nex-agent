defmodule Nex.SkillRuntime do
  @moduledoc false

  import Kernel, except: [import: 1, import: 2]

  alias Nex.Agent.Config
  alias Nex.Agent.Workspace

  alias Nex.SkillRuntime.{
    CatalogEntry,
    Evolver,
    ExecutionTrace,
    GitHub,
    LegacyMigrator,
    Package,
    PreparedRun,
    Registry,
    SkillRunner,
    Store,
    Validator
  }

  @type search_hit :: map()

  @spec default_config() :: map()
  def default_config do
    %{
      "enabled" => false,
      "trace_dir" => "skill_runtime/runs",
      "index_dir" => "skill_runtime/index",
      "cache_dir" => "skill_runtime/cache",
      "snapshots_dir" => "skill_runtime/snapshots",
      "max_selected_skills" => 2,
      "prefilter_limit" => 20,
      "post_run_analysis" => true,
      "github_indexes" => []
    }
  end

  @spec config(keyword()) :: map()
  def config(opts \\ []) do
    config =
      Keyword.get_lazy(opts, :config, fn ->
        Config.load(config_path: Keyword.get(opts, :config_path))
      end)

    base =
      if function_exported?(Config, :skill_runtime, 1) do
        apply(Config, :skill_runtime, [config])
      else
        default_config()
      end

    Map.merge(base, Keyword.get(opts, :skill_runtime, %{}))
  end

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    config(opts)["enabled"] == true
  end

  @spec search(String.t(), keyword()) :: {:ok, [search_hit()]} | {:error, String.t()}
  def search(query, opts \\ []) when is_binary(query) do
    with {:ok, runtime_opts} <- bootstrap(opts, true) do
      {:ok, Registry.search(query, runtime_opts)}
    end
  end

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def get(identifier, opts \\ []) when is_binary(identifier) and identifier != "" do
    with {:ok, runtime_opts} <- bootstrap(opts, true) do
      case Registry.package_by_skill_id(identifier, runtime_opts) ||
             Registry.package_by_source_id(identifier, runtime_opts) do
        %Package{} = package ->
          {:ok, build_get_payload(package)}

        nil ->
          case Enum.find(Registry.catalog(runtime_opts), &(&1.source_id == identifier)) do
            %CatalogEntry{} = entry ->
              with {:ok, package} <- GitHub.import_entry(entry, runtime_opts) do
                {:ok, build_get_payload(package)}
              end

            nil ->
              {:error, "Skill package not found: #{identifier}"}
          end
      end
    end
  end

  @spec capture(map(), keyword()) :: {:ok, Package.t()} | {:error, String.t()}
  def capture(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, runtime_opts} <- bootstrap(opts, false) do
      name = Map.get(attrs, "name") || Map.get(attrs, :name)
      description = Map.get(attrs, "description") || Map.get(attrs, :description) || ""
      content = Map.get(attrs, "content") || Map.get(attrs, :content) || ""
      references = normalize_list(Map.get(attrs, "references") || Map.get(attrs, :references))

      with true <- (is_binary(name) and String.trim(name) != "") || {:error, "name is required"},
           true <-
             (is_binary(content) and String.trim(content) != "") ||
               {:error, "content is required"},
           target_path <- local_runtime_dir(name, runtime_opts),
           :ok <- ensure_target_absent(target_path, "runtime package already exists: #{name}"),
           :ok <- File.mkdir_p(target_path),
           :ok <-
             File.write(
               Path.join(target_path, "SKILL.md"),
               build_skill_markdown(name, description, content, references)
             ),
           :ok <- write_skill_id(target_path, "captured:#{name}"),
           :ok <-
             write_source_json(target_path, %{
               "source_type" => "captured",
               "created_by" => "skill_capture",
               "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
               "active" => true
             }),
           {:ok, package} <- Package.from_dir(target_path),
           :ok <- Validator.validate_package(package) do
        Store.upsert_packages([package], runtime_opts)
        Registry.reload(runtime_opts)
        {:ok, package}
      end
    end
  end

  @spec import(String.t() | map() | CatalogEntry.t(), keyword()) ::
          {:ok, Package.t()} | {:error, String.t()}
  def import(source_id, opts) when is_binary(source_id) do
    with {:ok, runtime_opts} <- bootstrap(opts, true) do
      GitHub.import_by_source_id(source_id, runtime_opts)
    end
  end

  def import(%CatalogEntry{} = entry, opts) do
    with {:ok, runtime_opts} <- bootstrap(opts, true) do
      GitHub.import_entry(entry, runtime_opts)
    end
  end

  def import(%{"source_id" => source_id}, opts) when is_binary(source_id) do
    __MODULE__.import(source_id, opts)
  end

  def import(%{"repo" => repo, "commit_sha" => commit_sha, "path" => path} = attrs, opts)
      when is_binary(repo) and is_binary(commit_sha) and is_binary(path) do
    entry =
      attrs
      |> Map.put_new("source_id", Package.slugify("#{repo}-#{path}"))
      |> CatalogEntry.from_map()

    __MODULE__.import(entry, opts)
  end

  @spec sync(keyword()) :: {:ok, map()} | {:error, String.t()}
  def sync(opts \\ []) do
    with {:ok, runtime_opts} <- bootstrap(opts, true) do
      GitHub.sync_installed(runtime_opts)
    end
  end

  @spec prepare_run(String.t(), keyword()) :: {:ok, PreparedRun.t()} | {:error, String.t()}
  def prepare_run(prompt, opts \\ []) when is_binary(prompt) do
    opts = merged_opts(opts)

    if not enabled?(opts) do
      {:ok, %PreparedRun{}}
    else
      with {:ok, runtime_opts} <- bootstrap(opts, true) do
        hits = Registry.search(prompt, runtime_opts)
        max_selected = config(runtime_opts)["max_selected_skills"] || 2

        {packages, warnings} =
          hits
          |> Enum.take(max_selected * 3)
          |> Enum.reduce_while({[], []}, fn hit, {selected, warnings} ->
            cond do
              length(selected) >= max_selected ->
                {:halt, {selected, warnings}}

              hit.type == :local ->
                package = hit.package

                if package.active and package.available do
                  {:cont, {[package | selected], warnings}}
                else
                  {:cont, {selected, warnings ++ package.availability_warnings}}
                end

              hit.type == :remote and hit.installed ->
                case Registry.package_by_source_id(hit.entry.source_id, runtime_opts) do
                  %Package{} = package when package.active and package.available ->
                    {:cont, {[package | selected], warnings}}

                  %Package{} = package ->
                    {:cont, {selected, warnings ++ package.availability_warnings}}

                  nil ->
                    {:cont, {selected, warnings}}
                end

              hit.type == :remote ->
                case __MODULE__.import(hit.entry, runtime_opts) do
                  {:ok, package} ->
                    if package.active and package.available do
                      {:cont, {[package | selected], warnings}}
                    else
                      {:cont, {selected, warnings ++ package.availability_warnings}}
                    end

                  {:error, reason} ->
                    {:cont, {selected, warnings ++ [reason]}}
                end
            end
          end)

        packages = Enum.reverse(packages)

        {:ok,
         %PreparedRun{
           selected_packages: packages,
           prompt_fragments: Enum.map(packages, &build_prompt_fragment/1),
           ephemeral_tools: Enum.flat_map(packages, &ephemeral_tool/1),
           availability_warnings: Enum.uniq(warnings),
           remote_hits:
             hits
             |> Enum.filter(&(&1.type == :remote))
             |> Enum.map(fn %{entry: entry} -> CatalogEntry.to_map(entry) end)
         }}
      end
    end
  end

  @spec record_run(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def record_run(trace, opts \\ []) when is_map(trace) do
    with {:ok, runtime_opts} <- bootstrap(opts, false) do
      Store.append_run(struct(ExecutionTrace, Enum.into(trace, %{})), runtime_opts)
    end
  end

  @spec evolve(map(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def evolve(trace, opts \\ []) do
    with {:ok, runtime_opts} <- bootstrap(opts, false) do
      Evolver.evolve(trace, runtime_opts)
    end
  end

  @spec execute_ephemeral_tool(String.t(), map(), map()) :: {:ok, any()} | {:error, String.t()}
  def execute_ephemeral_tool(
        tool_name,
        args,
        %{skill_runtime_prepared_run: %PreparedRun{} = prepared_run} = ctx
      ) do
    case Enum.find(prepared_run.selected_packages, &(&1.tool_name == tool_name)) do
      %Package{} = package ->
        SkillRunner.execute(package, args, Map.put(ctx, :tool_name, tool_name))

      nil ->
        {:error, "Unknown runtime skill tool: #{tool_name}"}
    end
  end

  def execute_ephemeral_tool(_tool_name, _args, _ctx), do: {:error, "Unknown runtime skill tool"}

  defp maybe_sync_catalog(opts) do
    if config(opts)["github_indexes"] == [] do
      :ok
    else
      case GitHub.sync_catalog(opts) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end
  end

  defp merged_opts(opts) do
    Keyword.put(opts, :skill_runtime, config(opts))
  end

  defp bootstrap(opts, sync_catalog?) do
    opts = merged_opts(opts)
    ensure_enabled(opts)
    Store.ensure!(opts)
    _ = LegacyMigrator.migrate(opts)

    if sync_catalog? do
      maybe_sync_catalog(opts)
    end

    Registry.reload(opts)
    {:ok, opts}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp ensure_enabled(opts) do
    if enabled?(opts) do
      :ok
    else
      raise disabled_error()
    end
  end

  defp ensure_target_absent(path, message) do
    if File.exists?(path) do
      {:error, message}
    else
      :ok
    end
  end

  defp disabled_error, do: "SkillRuntime is disabled in config"

  defp build_get_payload(%Package{} = package) do
    %{
      "skill_id" => package.skill_id,
      "name" => package.name,
      "root_path" => package.root_path,
      "execution_mode" => package.execution_mode,
      "active" => package.active,
      "available" => package.available,
      "availability_warnings" => package.availability_warnings,
      "source_type" => package.source_type,
      "source" => package.source || %{},
      "manifest" => %{
        "name" => package.manifest.name,
        "description" => package.manifest.description,
        "version" => package.manifest.version,
        "execution_mode" => package.manifest.execution_mode,
        "entry_script" => package.manifest.entry_script,
        "dependencies" => package.manifest.dependencies,
        "required_keys" => package.manifest.required_keys,
        "parameters" => package.manifest.parameters,
        "allowed_tools" => package.manifest.allowed_tools,
        "references" => package.manifest.references,
        "requires" => package.manifest.requires,
        "host_compat" => package.manifest.host_compat,
        "risk_level" => package.manifest.risk_level
      },
      "progressive_disclosure" => progressive_disclosure(package)
    }
  end

  defp progressive_disclosure(%Package{execution_mode: "playbook"} = package) do
    %{
      "when_to_use" => String.slice(package.manifest.content || "", 0, 1200),
      "entry_script" => package.manifest.entry_script,
      "parameters" =>
        package.manifest.parameters || %{"type" => "object", "additionalProperties" => true}
    }
  end

  defp progressive_disclosure(%Package{} = package) do
    %{
      "content" => String.slice(package.manifest.content || "", 0, 4000),
      "references" =>
        Enum.flat_map(package.manifest.references, fn reference ->
          case Package.read_reference(package, reference) do
            {:ok, content} ->
              [
                %{
                  "path" => reference,
                  "content" => String.slice(content, 0, 2000)
                }
              ]

            _ ->
              []
          end
        end)
    }
  end

  defp local_runtime_dir(name, opts) do
    Path.join(Workspace.skills_dir(opts), "rt__#{Package.slugify(name)}")
  end

  defp build_skill_markdown(name, description, content, references) do
    lines =
      [
        "---",
        "name: #{yaml_scalar(name)}",
        "description: #{yaml_scalar(description)}",
        "execution_mode: knowledge",
        "version: 1"
      ] ++
        references_lines(references) ++
        ["---", "", String.trim(content), ""]

    Enum.join(lines, "\n")
  end

  defp references_lines([]), do: []

  defp references_lines(references) do
    ["references:" | Enum.map(references, &"  - #{yaml_scalar(&1)}")]
  end

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(value) when is_binary(value), do: [String.trim(value)]
  defp normalize_list(_), do: []

  defp write_skill_id(path, seed) do
    skill_id =
      "skill_" <>
        (:crypto.hash(:sha256, seed)
         |> Base.encode16(case: :lower)
         |> String.slice(0, 16))

    File.write(Path.join(path, ".skill_id"), skill_id <> "\n")
  end

  defp write_source_json(path, payload) do
    File.write(Path.join(path, "source.json"), Jason.encode!(payload, pretty: true))
  end

  defp yaml_scalar(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp yaml_scalar(value), do: to_string(value)

  defp build_prompt_fragment(%Package{} = package) do
    base = [
      "[Skill Package]",
      "Name: #{package.name}",
      "Mode: #{package.execution_mode}",
      "Description: #{package.manifest.description}"
    ]

    case package.execution_mode do
      "playbook" ->
        lines =
          base ++
            [
              "Tool: #{package.tool_name}",
              "Entry Script: #{package.manifest.entry_script}",
              "Parameters Schema: #{Jason.encode!(package.manifest.parameters || %{"type" => "object", "additionalProperties" => true})}",
              "When to use: #{String.slice(package.manifest.content || "", 0, 1200)}"
            ]

        Enum.join(lines, "\n")

      _ ->
        references =
          package.manifest.references
          |> Enum.map(fn reference ->
            case Package.read_reference(package, reference) do
              {:ok, content} ->
                "Reference #{reference}:\n#{String.slice(content, 0, 2000)}"

              {:error, _} ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        (base ++
           ["Instructions:\n#{String.slice(package.manifest.content || "", 0, 4000)}"] ++
           references)
        |> Enum.join("\n\n")
    end
  end

  defp ephemeral_tool(%Package{execution_mode: "playbook"} = package) do
    [
      %{
        "name" => package.tool_name,
        "description" => package.manifest.description || "Run playbook skill #{package.name}",
        "input_schema" =>
          package.manifest.parameters || %{"type" => "object", "additionalProperties" => true}
      }
    ]
  end

  defp ephemeral_tool(_package), do: []
end
