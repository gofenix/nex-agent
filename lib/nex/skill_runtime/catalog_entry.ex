defmodule Nex.SkillRuntime.CatalogEntry do
  @moduledoc false

  defstruct [
    :source_id,
    :repo,
    :commit_sha,
    :path,
    :name,
    :description,
    :version,
    :execution_mode,
    :entry_script,
    :dependencies,
    :required_keys,
    :allowed_tools,
    :tags,
    :host_compat,
    :risk_level,
    :file_manifest,
    :package_checksum,
    :installed,
    :score,
    :index_repo,
    :index_ref
  ]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      source_id: map["source_id"],
      repo: map["repo"],
      commit_sha: map["commit_sha"] || map["commit"],
      path: map["path"],
      name: map["name"],
      description: map["description"] || "",
      version: normalize_version(map["version"]),
      execution_mode: map["execution_mode"],
      entry_script: map["entry_script"],
      dependencies: normalize_list(map["dependencies"]),
      required_keys: normalize_list(map["required_keys"]),
      allowed_tools: normalize_list(map["allowed_tools"]),
      tags: normalize_list(map["tags"]),
      host_compat: normalize_list(map["host_compat"]),
      risk_level: map["risk_level"],
      file_manifest: map["file_manifest"] || %{},
      package_checksum: map["package_checksum"],
      installed: map["installed"] == true,
      score: normalize_score(map["score"]),
      index_repo: map["index_repo"],
      index_ref: map["index_ref"]
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      "source_id" => entry.source_id,
      "repo" => entry.repo,
      "commit_sha" => entry.commit_sha,
      "path" => entry.path,
      "name" => entry.name,
      "description" => entry.description,
      "version" => entry.version,
      "execution_mode" => entry.execution_mode,
      "entry_script" => entry.entry_script,
      "dependencies" => entry.dependencies,
      "required_keys" => entry.required_keys,
      "allowed_tools" => entry.allowed_tools,
      "tags" => entry.tags,
      "host_compat" => entry.host_compat,
      "risk_level" => entry.risk_level,
      "file_manifest" => entry.file_manifest,
      "package_checksum" => entry.package_checksum,
      "installed" => entry.installed,
      "score" => entry.score,
      "index_repo" => entry.index_repo,
      "index_ref" => entry.index_ref
    }
  end

  @spec search_text(t()) :: String.t()
  def search_text(%__MODULE__{} = entry) do
    [
      entry.name,
      entry.description,
      Enum.join(entry.tags || [], " "),
      Enum.join(entry.dependencies || [], " "),
      Enum.join(entry.allowed_tools || [], " ")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(value) when is_binary(value), do: [value]
  defp normalize_list(_), do: []

  defp normalize_version(value) when is_integer(value), do: value

  defp normalize_version(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp normalize_version(_), do: 0

  defp normalize_score(value) when is_number(value), do: value * 1.0
  defp normalize_score(_), do: 0.0
end
