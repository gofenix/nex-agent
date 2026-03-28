defmodule Nex.SkillRuntime.Manifest do
  @moduledoc false

  alias Nex.SkillRuntime.Frontmatter

  defstruct [
    :name,
    :description,
    :version,
    :execution_mode,
    :entry_script,
    :dependencies,
    :required_keys,
    :parameters,
    :allowed_tools,
    :references,
    :requires,
    :host_compat,
    :risk_level,
    :content,
    :path,
    :raw
  ]

  @type t :: %__MODULE__{}

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, content} <- File.read(path) do
      {frontmatter, body} = Frontmatter.parse_document(content)
      name = frontmatter["name"] || Path.basename(Path.dirname(path))

      {:ok,
       %__MODULE__{
         name: name,
         description: frontmatter["description"] || extract_first_paragraph(body),
         version: normalize_version(frontmatter["version"]),
         execution_mode: normalize_execution_mode(frontmatter["execution_mode"]),
         entry_script: normalize_string(frontmatter["entry_script"]),
         dependencies: normalize_list(frontmatter["dependencies"]),
         required_keys: normalize_list(frontmatter["required_keys"]),
         parameters: normalize_parameters(frontmatter["parameters"]),
         allowed_tools:
           normalize_list(frontmatter["allowed_tools"] || frontmatter["allowed-tools"]),
         references: normalize_list(frontmatter["references"]),
         requires: normalize_requires(frontmatter["requires"]),
         host_compat: normalize_list(frontmatter["host_compat"] || frontmatter["host-compat"]),
         risk_level: normalize_string(frontmatter["risk_level"] || frontmatter["risk-level"]),
         content: String.trim(body),
         path: path,
         raw: frontmatter
       }}
    end
  end

  @spec infer_execution_mode(t(), String.t()) :: String.t()
  def infer_execution_mode(%__MODULE__{execution_mode: mode}, _package_root)
      when mode in ["knowledge", "playbook"],
      do: mode

  def infer_execution_mode(_manifest, package_root) do
    if has_extra_files?(package_root), do: "playbook", else: "knowledge"
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    %{
      "name" => manifest.name,
      "description" => manifest.description,
      "version" => manifest.version,
      "execution_mode" => manifest.execution_mode,
      "entry_script" => manifest.entry_script,
      "dependencies" => manifest.dependencies,
      "required_keys" => manifest.required_keys,
      "parameters" => manifest.parameters,
      "allowed_tools" => manifest.allowed_tools,
      "references" => manifest.references,
      "requires" => manifest.requires,
      "host_compat" => manifest.host_compat,
      "risk_level" => manifest.risk_level,
      "content" => manifest.content,
      "path" => manifest.path
    }
  end

  defp extract_first_paragraph(body) do
    body
    |> String.split("\n\n")
    |> List.first()
    |> case do
      nil -> ""
      para -> para |> String.trim() |> String.slice(0..200)
    end
  end

  defp has_extra_files?(package_root) do
    package_root
    |> Path.expand()
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.any?(fn path ->
      File.regular?(path) and Path.basename(path) != "SKILL.md" and not hidden_file?(path)
    end)
  end

  defp hidden_file?(path) do
    path
    |> Path.split()
    |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp normalize_execution_mode(mode) when mode in ["knowledge", "playbook"], do: mode
  defp normalize_execution_mode(_), do: nil

  defp normalize_version(version) when is_integer(version) and version >= 0, do: version

  defp normalize_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp normalize_version(_), do: 0

  defp normalize_parameters(params) when is_map(params), do: stringify_keys(params)
  defp normalize_parameters(_), do: nil

  defp stringify_keys(map) do
    Enum.into(map, %{}, fn {key, value} ->
      normalized =
        if is_map(value) do
          stringify_keys(value)
        else
          value
        end

      {to_string(key), normalized}
    end)
  end

  defp normalize_list(nil), do: []
  defp normalize_list(""), do: []

  defp normalize_list(list) when is_list(list),
    do: Enum.map(list, &normalize_string/1) |> Enum.reject(&is_nil/1)

  defp normalize_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(_), do: []

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_), do: nil

  defp normalize_requires(nil), do: %{}
  defp normalize_requires(map) when is_map(map), do: stringify_keys(map)

  defp normalize_requires(value) when is_binary(value) do
    %{"bins" => normalize_list(value), "env" => []}
  end

  defp normalize_requires(_), do: %{}
end
