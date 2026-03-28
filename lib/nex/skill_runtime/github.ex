defmodule Nex.SkillRuntime.GitHub do
  @moduledoc false

  alias Nex.Agent.Workspace
  alias Nex.SkillRuntime.{CatalogEntry, GitHubAuth, Package, Registry, Store, Validator}

  @spec sync_catalog(keyword()) :: {:ok, [CatalogEntry.t()]} | {:error, String.t()}
  def sync_catalog(opts \\ []) do
    indexes =
      opts
      |> skill_runtime_config()
      |> Map.get("github_indexes", [])

    entries =
      Enum.flat_map(indexes, fn index ->
        load_index(index, opts)
      end)

    entries =
      entries
      |> Enum.map(&CatalogEntry.from_map/1)
      |> Enum.uniq_by(& &1.source_id)

    Store.ensure!(opts)
    Store.write_catalog(entries, opts)
    Registry.load_catalog(opts)
    {:ok, entries}
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  @spec import_entry(CatalogEntry.t(), keyword()) :: {:ok, Package.t()} | {:error, String.t()}
  def import_entry(%CatalogEntry{} = entry, opts \\ []) do
    import_entry(entry, opts, MapSet.new())
  end

  @spec import_by_source_id(String.t(), keyword()) :: {:ok, Package.t()} | {:error, String.t()}
  def import_by_source_id(source_id, opts \\ []) when is_binary(source_id) do
    entry =
      opts
      |> Registry.catalog()
      |> Enum.find(&(&1.source_id == source_id))

    case entry do
      nil -> {:error, "catalog entry not found: #{source_id}"}
      found -> import_entry(found, opts)
    end
  end

  @spec sync_installed(keyword()) :: {:ok, map()} | {:error, String.t()}
  def sync_installed(opts \\ []) do
    with {:ok, _entries} <- sync_catalog(opts) do
      installed =
        Registry.packages(opts)
        |> Enum.filter(&(get_in(&1.source || %{}, ["source_id"]) != nil))

      result =
        Enum.reduce(installed, %{updated: [], skipped: []}, fn package, acc ->
          source_id = get_in(package.source || %{}, ["source_id"])
          current_commit = get_in(package.source || %{}, ["source_commit"])

          case Enum.find(Registry.catalog(opts), &(&1.source_id == source_id)) do
            %CatalogEntry{commit_sha: ^current_commit} ->
              %{acc | skipped: [source_id | acc.skipped]}

            %CatalogEntry{} = entry ->
              case import_entry(entry, opts) do
                {:ok, _package} -> %{acc | updated: [source_id | acc.updated]}
                {:error, _} -> %{acc | skipped: [source_id | acc.skipped]}
              end

            nil ->
              %{acc | skipped: [source_id | acc.skipped]}
          end
        end)

      {:ok, result}
    end
  end

  defp import_entry(%CatalogEntry{} = entry, opts, visited) do
    if MapSet.member?(visited, entry.source_id) do
      {:error, "dependency cycle detected at #{entry.source_id}"}
    else
      visited = MapSet.put(visited, entry.source_id)

      with {:ok, dependency_status} <- import_dependencies(entry, opts, visited),
           :ok <- Store.ensure!(opts),
           {:ok, cache_dir} <- download_package(entry, opts),
           {:ok, package_dir} <- install_package(entry, cache_dir, dependency_status, opts),
           {:ok, package} <- Package.from_dir(package_dir),
           :ok <- Validator.validate_package(package) do
        Store.upsert_packages([package], opts)
        Registry.reload(opts)
        {:ok, package}
      end
    end
  end

  defp import_dependencies(%CatalogEntry{dependencies: dependencies}, _opts, _visited)
       when dependencies in [nil, []],
       do: {:ok, %{active: true, availability_warnings: []}}

  defp import_dependencies(%CatalogEntry{} = entry, opts, visited) do
    Enum.reduce(entry.dependencies, %{active: true, availability_warnings: []}, fn dependency,
                                                                                   acc ->
      dependency_entry =
        Registry.catalog(opts)
        |> Enum.find(&(&1.source_id == dependency))

      case dependency_entry do
        nil ->
          inactive_dependency(acc, "missing dependency #{dependency}")

        %CatalogEntry{} = found ->
          case import_entry(found, opts, visited) do
            {:ok, package} when package.active and package.available ->
              acc

            {:ok, package} ->
              package.availability_warnings
              |> case do
                [] -> ["dependency #{dependency} is unavailable"]
                warnings -> Enum.map(warnings, &"dependency #{dependency}: #{&1}")
              end
              |> Enum.reduce(acc, &inactive_dependency(&2, &1))

            {:error, reason} ->
              if String.contains?(reason, "dependency cycle detected") do
                raise reason
              else
                inactive_dependency(acc, "dependency #{dependency} import failed: #{reason}")
              end
          end
      end
    end)
    |> then(fn status ->
      {:ok, %{status | availability_warnings: Enum.uniq(status.availability_warnings)}}
    end)
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp load_index(index, opts) do
    repo = index["repo"] || index[:repo]
    ref = index["ref"] || index[:ref] || "main"
    path = index["path"] || index[:path] || "index.json"

    with {:ok, file} <- github_contents_file(repo, path, ref, opts),
         {:ok, content} <- decode_contents(file),
         {:ok, decoded} <- Jason.decode(content) do
      entries =
        cond do
          is_list(decoded) -> decoded
          is_map(decoded) and is_list(decoded["skills"]) -> decoded["skills"]
          true -> []
        end

      Enum.map(entries, fn entry ->
        entry
        |> Map.put_new("index_repo", repo)
        |> Map.put_new("index_ref", ref)
      end)
    else
      _ -> []
    end
  end

  defp download_package(%CatalogEntry{} = entry, opts) do
    cache_root =
      Path.join([
        Store.cache_dir(opts),
        "github",
        cache_segment(entry.repo),
        entry.commit_sha
      ])

    path_segment = entry.path |> String.split("/") |> Enum.reject(&(&1 == ""))
    target = Path.join([cache_root | path_segment])

    File.rm_rf!(target)
    File.mkdir_p!(target)

    with :ok <- download_dir(entry.repo, entry.path, entry.commit_sha, target, opts) do
      {:ok, target}
    end
  end

  defp install_package(%CatalogEntry{} = entry, cache_dir, dependency_status, opts) do
    target_dir = Path.join(Workspace.skills_dir(opts), "gh__#{Package.slugify(entry.source_id)}")

    if File.dir?(target_dir) do
      case Package.from_dir(target_dir) do
        {:ok, package} -> Store.snapshot_package(package, opts)
        _ -> :ok
      end
    end

    File.rm_rf!(target_dir)
    File.mkdir_p!(Path.dirname(target_dir))
    File.cp_r!(cache_dir, target_dir)
    write_skill_id!(target_dir, entry)
    write_source!(target_dir, entry, dependency_status)
    {:ok, target_dir}
  end

  defp download_dir(repo, path, ref, local_dir, opts) do
    with {:ok, response} <- github_contents(repo, path, ref, opts) do
      items = if is_list(response), do: response, else: [response]

      Enum.reduce_while(items, :ok, fn item, :ok ->
        case item["type"] do
          "file" ->
            case download_file(item, Path.join(local_dir, item["name"]), opts) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          "dir" ->
            sub_dir = Path.join(local_dir, item["name"])
            File.mkdir_p!(sub_dir)

            case download_dir(repo, item["path"], ref, sub_dir, opts) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          _ ->
            {:cont, :ok}
        end
      end)
    end
  end

  defp download_file(item, target, opts) do
    cond do
      is_binary(item["download_url"]) ->
        case request(item["download_url"], opts, headers: GitHubAuth.headers()) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            File.write!(target, body)
            :ok

          {:ok, %{status: status}} ->
            {:error, "download failed with status #{status}"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      is_binary(item["content"]) ->
        case Base.decode64(item["content"], ignore: :whitespace) do
          {:ok, decoded} ->
            File.write!(target, decoded)
            :ok

          :error ->
            {:error, "invalid base64 content for #{item["path"]}"}
        end

      true ->
        {:error, "missing download_url for #{item["path"]}"}
    end
  end

  defp github_contents_file(repo, path, ref, opts) do
    case github_contents(repo, path, ref, opts) do
      {:ok, response} when is_map(response) -> {:ok, response}
      {:ok, [response]} when is_map(response) -> {:ok, response}
      {:ok, _} -> {:error, "unexpected index response"}
      error -> error
    end
  end

  defp github_contents(repo, path, ref, opts) do
    url = "https://api.github.com/repos/#{repo}/contents/#{path}?ref=#{ref}"

    case request(url, opts, headers: GitHubAuth.headers()) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, %{status: status, body: body}} ->
        {:error,
         "github request failed with status #{status}: #{String.slice(body || "", 0, 200)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp decode_contents(%{"content" => content}) do
    Base.decode64(content, ignore: :whitespace)
  end

  defp request(url, opts, req_opts) do
    request_fun = Keyword.get(opts, :http_get)

    if is_function(request_fun, 2) do
      request_fun.(url, req_opts)
    else
      Req.get(
        url,
        Keyword.merge([retry: false, receive_timeout: 30_000, finch: Req.Finch], req_opts)
      )
    end
  end

  defp write_skill_id!(dir, entry) do
    skill_id =
      "skill_" <> String.slice(hash_text("#{entry.source_id}:#{entry.commit_sha}"), 0, 16)

    File.write!(Path.join(dir, ".skill_id"), skill_id <> "\n")
  end

  defp write_source!(dir, entry, dependency_status) do
    data = %{
      "source_id" => entry.source_id,
      "index_repo" => entry.index_repo,
      "index_ref" => entry.index_ref,
      "source_repo" => entry.repo,
      "source_commit" => entry.commit_sha,
      "source_path" => entry.path,
      "file_manifest" => entry.file_manifest,
      "package_checksum" => entry.package_checksum,
      "imported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "active" => dependency_status.active,
      "availability_warnings" => dependency_status.availability_warnings
    }

    File.write!(Path.join(dir, "source.json"), Jason.encode!(data, pretty: true))
  end

  defp inactive_dependency(acc, warning) do
    %{
      active: false,
      availability_warnings: acc.availability_warnings ++ [warning]
    }
  end

  defp cache_segment(value),
    do: value |> String.replace("/", "__") |> String.replace(~r/[^a-zA-Z0-9_]+/, "_")

  defp hash_text(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp skill_runtime_config(opts),
    do: Map.merge(Nex.SkillRuntime.default_config(), Keyword.get(opts, :skill_runtime, %{}))
end
