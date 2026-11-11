defmodule Nex.SkillRuntime.Package do
  @moduledoc false

  alias Nex.SkillRuntime.Manifest

  defstruct [
    :skill_id,
    :name,
    :slug,
    :root_path,
    :manifest,
    :draft,
    :files,
    :source,
    :source_type,
    :installed,
    :active,
    :available,
    :availability_warnings,
    :execution_mode,
    :tool_name
  ]

  @type t :: %__MODULE__{}

  @spec from_dir(String.t()) :: {:ok, t()} | {:error, term()}
  def from_dir(dir) when is_binary(dir) do
    skill_md = Path.join(dir, "SKILL.md")

    with true <- File.exists?(skill_md) || {:error, :missing_skill_md},
         {:ok, manifest} <- Manifest.load(skill_md) do
      source = read_source(dir)
      execution_mode = Manifest.infer_execution_mode(manifest, dir)
      {available, warnings} = availability(manifest, source)
      draft = manifest.draft == true
      active = source_active?(source) and not draft

      package =
        %__MODULE__{
          skill_id: read_skill_id(dir) || generated_skill_id(dir, manifest.name),
          name: manifest.name,
          slug: slugify(manifest.name),
          root_path: Path.expand(dir),
          manifest: %{manifest | execution_mode: execution_mode},
          draft: draft,
          files: list_files(dir),
          source: source,
          source_type: source_type(source),
          installed: true,
          active: active,
          available: available,
          availability_warnings: warnings,
          execution_mode: execution_mode,
          tool_name: if(execution_mode == "playbook", do: "skill_run__#{slugify(manifest.name)}")
        }

      {:ok, package}
    end
  end

  @spec to_record(t()) :: map()
  def to_record(%__MODULE__{} = package) do
    %{
      "skill_id" => package.skill_id,
      "name" => package.name,
      "slug" => package.slug,
      "root_path" => package.root_path,
      "draft" => package.draft == true,
      "installed" => package.installed,
      "active" => package.active,
      "available" => package.available,
      "availability_warnings" => package.availability_warnings,
      "execution_mode" => package.execution_mode,
      "source_type" => package.source_type,
      "tool_name" => package.tool_name,
      "manifest" => Manifest.to_map(package.manifest),
      "source" => package.source,
      "files" => package.files
    }
  end

  @spec from_record(map()) :: t()
  def from_record(record) when is_map(record) do
    manifest =
      %Manifest{
        name: get_in(record, ["manifest", "name"]) || record["name"],
        description: get_in(record, ["manifest", "description"]) || "",
        draft: get_in(record, ["manifest", "draft"]) == true or record["draft"] == true,
        version: get_in(record, ["manifest", "version"]) || 0,
        execution_mode: get_in(record, ["manifest", "execution_mode"]),
        entry_script: get_in(record, ["manifest", "entry_script"]),
        dependencies: get_in(record, ["manifest", "dependencies"]) || [],
        required_keys: get_in(record, ["manifest", "required_keys"]) || [],
        parameters: get_in(record, ["manifest", "parameters"]),
        allowed_tools: get_in(record, ["manifest", "allowed_tools"]) || [],
        references: get_in(record, ["manifest", "references"]) || [],
        requires: get_in(record, ["manifest", "requires"]) || %{},
        host_compat: get_in(record, ["manifest", "host_compat"]) || [],
        risk_level: get_in(record, ["manifest", "risk_level"]),
        content: get_in(record, ["manifest", "content"]) || "",
        path: get_in(record, ["manifest", "path"]),
        raw: %{}
      }

    %__MODULE__{
      skill_id: record["skill_id"],
      name: record["name"],
      slug: record["slug"] || slugify(record["name"] || "skill"),
      root_path: record["root_path"],
      manifest: manifest,
      draft: record["draft"] == true or manifest.draft == true,
      files: record["files"] || [],
      source: record["source"],
      source_type: record["source_type"] || "local",
      installed: record["installed"] != false,
      active:
        record["active"] != false and not (record["draft"] == true or manifest.draft == true),
      available: record["available"] != false,
      availability_warnings: record["availability_warnings"] || [],
      execution_mode: record["execution_mode"] || manifest.execution_mode || "knowledge",
      tool_name: record["tool_name"]
    }
  end

  @spec search_text(t()) :: String.t()
  def search_text(%__MODULE__{} = package) do
    [
      package.name,
      package.manifest.description,
      package.manifest.content,
      Enum.join(package.manifest.dependencies || [], " "),
      Enum.join(package.manifest.allowed_tools || [], " ")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  @spec read_reference(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_reference(%__MODULE__{} = package, relative_path) when is_binary(relative_path) do
    path = safe_join(package.root_path, relative_path)

    cond do
      is_nil(path) -> {:error, :invalid_reference_path}
      not File.exists?(path) -> {:error, :missing_reference}
      true -> File.read(path)
    end
  end

  @spec safe_join(String.t(), String.t()) :: String.t() | nil
  def safe_join(root, relative_path) do
    expanded_root = Path.expand(root)
    joined = Path.expand(Path.join(expanded_root, relative_path))

    if String.starts_with?(joined, expanded_root <> "/") or joined == expanded_root do
      joined
    else
      nil
    end
  end

  @spec slugify(String.t()) :: String.t()
  def slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "skill"
      slug -> slug
    end
  end

  defp list_files(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(fn path ->
      path
      |> Path.relative_to(dir)
      |> Path.split()
      |> Enum.any?(&String.starts_with?(&1, "."))
    end)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  defp read_skill_id(dir) do
    case File.read(Path.join(dir, ".skill_id")) do
      {:ok, content} ->
        content = String.trim(content)
        if content == "", do: nil, else: content

      {:error, _} ->
        nil
    end
  end

  defp generated_skill_id(dir, name) do
    hash =
      :crypto.hash(:sha256, Path.expand(dir) <> ":" <> to_string(name))
      |> Base.encode16(case: :lower)

    "skill_" <> String.slice(hash, 0, 16)
  end

  defp read_source(dir) do
    source_path = Path.join(dir, "source.json")

    with true <- File.exists?(source_path),
         {:ok, content} <- File.read(source_path),
         {:ok, data} <- Jason.decode(content) do
      data
    else
      _ -> nil
    end
  end

  defp source_type(%{"source_type" => source_type})
       when is_binary(source_type) and source_type != "",
       do: source_type

  defp source_type(%{"source_id" => _}), do: "github"
  defp source_type(_), do: "local"

  defp source_active?(%{"active" => value}) when value in [false, "false"], do: false
  defp source_active?(_), do: true

  defp availability(manifest, source) do
    source_warnings =
      case source do
        %{"availability_warnings" => warnings} when is_list(warnings) ->
          Enum.map(warnings, &to_string/1)

        _ ->
          []
      end

    required_keys =
      manifest.required_keys
      |> Enum.reject(&(is_binary(System.get_env(&1)) and System.get_env(&1) != ""))
      |> Enum.map(&"missing env #{&1}")

    require_bins =
      manifest.requires
      |> Map.get("bins", [])
      |> Enum.reject(&(System.find_executable(&1) != nil))
      |> Enum.map(&"missing binary #{&1}")

    require_env =
      manifest.requires
      |> Map.get("env", [])
      |> Enum.reject(&(is_binary(System.get_env(&1)) and System.get_env(&1) != ""))
      |> Enum.map(&"missing env #{&1}")

    warnings = source_warnings ++ required_keys ++ require_bins ++ require_env
    {warnings == [], Enum.uniq(warnings)}
  end
end
