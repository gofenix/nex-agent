defmodule Nex.SkillRuntime.Registry do
  @moduledoc false

  alias Nex.Agent.Workspace
  alias Nex.SkillRuntime.{CatalogEntry, Package, Store}

  @table :nex_skill_runtime_registry
  @k1 1.2
  @b 0.75

  @spec packages(keyword()) :: [Package.t()]
  def packages(opts \\ []) do
    key = cache_key(:packages, opts)

    case lookup(key) do
      nil ->
        reload(opts)

      value ->
        value
    end
  end

  @spec package_by_skill_id(String.t(), keyword()) :: Package.t() | nil
  def package_by_skill_id(skill_id, opts \\ []) when is_binary(skill_id) do
    Enum.find(packages(opts), &(&1.skill_id == skill_id))
  end

  @spec package_by_source_id(String.t(), keyword()) :: Package.t() | nil
  def package_by_source_id(source_id, opts \\ []) when is_binary(source_id) do
    Enum.find(packages(opts), &(get_in(&1.source || %{}, ["source_id"]) == source_id))
  end

  @spec catalog(keyword()) :: [CatalogEntry.t()]
  def catalog(opts \\ []) do
    key = cache_key(:catalog, opts)

    case lookup(key) do
      nil ->
        load_catalog(opts)

      value ->
        value
    end
  end

  @spec reload(keyword()) :: [Package.t()]
  def reload(opts \\ []) do
    packages =
      scan_dirs(opts)
      |> Enum.flat_map(fn dir ->
        dir
        |> File.ls!()
        |> Enum.flat_map(&load_entry(dir, &1))
      end)
      |> Enum.sort_by(&String.downcase(&1.name || ""))

    ensure_table()
    Store.ensure!(opts)
    Store.upsert_packages(packages, opts)
    :ets.insert(@table, {cache_key(:packages, opts), packages})
    packages
  end

  @spec search(String.t(), keyword()) :: [map()]
  def search(query, opts \\ []) when is_binary(query) do
    local_results =
      packages(opts)
      |> Enum.filter(& &1.active)
      |> score_documents(query, fn package -> Package.search_text(package) end)
      |> Enum.map(fn {package, score} ->
        %{
          type: :local,
          installed: true,
          score: score,
          package: package
        }
      end)

    remote_results =
      catalog(opts)
      |> score_documents(query, fn entry -> CatalogEntry.search_text(entry) end)
      |> Enum.map(fn {entry, score} ->
        %{
          type: :remote,
          installed: installed_source_id?(entry.source_id, opts),
          score: score,
          entry: %{entry | score: score}
        }
      end)

    limit = get_in(Keyword.get(opts, :skill_runtime, %{}), ["prefilter_limit"]) || 20

    (local_results ++ remote_results)
    |> Enum.sort_by(&{-&1.score, item_name(&1)})
    |> Enum.take(limit)
  end

  @spec load_catalog(keyword()) :: [CatalogEntry.t()]
  def load_catalog(opts \\ []) do
    entries = Store.load_catalog_records(opts)
    ensure_table()
    :ets.insert(@table, {cache_key(:catalog, opts), entries})
    entries
  end

  defp scan_dirs(opts) do
    [Workspace.skills_dir(opts)]
    |> Enum.filter(&File.dir?/1)
  end

  defp load_entry(dir, name) do
    path = Path.join(dir, name)

    if File.dir?(path) and
         (String.starts_with?(name, "rt__") or String.starts_with?(name, "gh__")) do
      case Package.from_dir(path) do
        {:ok, package} -> [package]
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp score_documents([], _query, _fun), do: []

  defp score_documents(documents, query, text_fun) do
    query_tokens = tokenize(query)

    if query_tokens == [] do
      Enum.map(documents, &{&1, 0.0})
    else
      doc_tokens = Enum.map(documents, fn doc -> {doc, tokenize(text_fun.(doc) || "")} end)

      avg_len =
        doc_tokens |> Enum.map(fn {_doc, tokens} -> max(length(tokens), 1) end) |> average()

      doc_freq =
        Enum.reduce(doc_tokens, %{}, fn {_doc, tokens}, acc ->
          tokens
          |> MapSet.new()
          |> Enum.reduce(acc, fn token, inner -> Map.update(inner, token, 1, &(&1 + 1)) end)
        end)

      count = max(length(doc_tokens), 1)

      doc_tokens
      |> Enum.map(fn {doc, tokens} ->
        score =
          Enum.reduce(query_tokens, 0.0, fn token, acc ->
            tf = Enum.count(tokens, &(&1 == token))

            if tf == 0 do
              acc
            else
              df = Map.get(doc_freq, token, 0)
              idf = :math.log(1 + (count - df + 0.5) / (df + 0.5))
              len = max(length(tokens), 1)
              denom = tf + @k1 * (1 - @b + @b * len / max(avg_len, 1))
              acc + idf * (tf * (@k1 + 1)) / denom
            end
          end)

        {doc, score}
      end)
      |> Enum.filter(fn {_doc, score} -> score > 0 end)
    end
  end

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]\s_-]+/u, " ")
    |> String.split(~r/\s+/, trim: true)
  end

  defp average([]), do: 1.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp installed_source_id?(source_id, opts) do
    Enum.any?(packages(opts), fn package ->
      get_in(package.source || %{}, ["source_id"]) == source_id
    end)
  end

  defp item_name(%{package: package}), do: package.name || ""
  defp item_name(%{entry: entry}), do: entry.name || ""

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _ -> @table
    end
  end

  defp lookup(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> nil
    end
  end

  defp cache_key(kind, opts) do
    {kind, Keyword.get(opts, :workspace) || Workspace.root(opts)}
  end
end
