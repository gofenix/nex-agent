defmodule Nex.Agent.Skills.Loader do
  @moduledoc """
  Skills loader - parses Markdown SKILL.md files.
  """

  @spec load_from_dir(String.t(), keyword()) :: list(map())
  def load_from_dir(dir, opts \\ []) do
    path = Path.expand(dir)
    filter_unavailable = Keyword.get(opts, :filter_unavailable, true)

    if File.exists?(path) do
      path
      |> File.ls!()
      |> Enum.filter(fn name ->
        has_skill_md?(name) || has_skill_dir?(path, name)
      end)
      |> Enum.flat_map(fn name -> load_skill(name, path) end)
      |> then(fn skills ->
        if filter_unavailable do
          Enum.filter(skills, &check_requirements/1)
        else
          skills
        end
      end)
    else
      []
    end
  end

  @spec load_all(keyword()) :: list(map())
  def load_all(opts \\ []) do
    global = Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace/skills")
    project = ".nex/skills"

    filter_unavailable = Keyword.get(opts, :filter_unavailable, true)
    loader_opts = [filter_unavailable: filter_unavailable]

    []
    |> Kernel.++(load_from_dir(global, loader_opts))
    |> Kernel.++(load_from_dir(project, loader_opts))
    |> Enum.uniq_by(& &1[:name])
  end

  @spec list_all() :: list(map())
  def list_all, do: load_all(filter_unavailable: false)

  @spec check_requirements(map()) :: boolean()
  def check_requirements(skill) do
    requires = skill[:requires] || %{}
    bins = requires[:bins] || []
    envs = requires[:env] || []

    Enum.all?(bins, &find_executable/1) and Enum.all?(envs, &System.get_env/1)
  end

  @spec missing_requirements(map()) :: String.t()
  def missing_requirements(skill) do
    requires = skill[:requires] || %{}
    bins = requires[:bins] || []
    envs = requires[:env] || []

    (Enum.map(Enum.reject(bins, &find_executable/1), &"CLI: #{&1}") ++
       Enum.map(Enum.reject(envs, &System.get_env/1), &"ENV: #{&1}"))
    |> Enum.join(", ")
  end

  defp has_skill_md?(name), do: String.ends_with?(name, ".md")

  defp has_skill_dir?(base_path, name) do
    File.dir?(Path.join(base_path, name))
  end

  defp load_skill(name, base_path) do
    skill_path = Path.join([base_path, name, "SKILL.md"])

    cond do
      File.dir?(Path.join(base_path, name)) and File.exists?(skill_path) ->
        [parse_skill_file(skill_path)]

      File.exists?(skill_path) ->
        [parse_skill_file(skill_path)]

      String.ends_with?(name, ".md") ->
        [parse_skill_file(Path.join(base_path, name))]

      true ->
        []
    end
  end

  defp parse_skill_file(path) do
    content = File.read!(path)

    case Regex.run(~r/^---\n(.*?)\n---\n?(.*)$/s, content) do
      [_, frontmatter, body] -> parse_skill(frontmatter, body, path)
      nil -> parse_skill("", content, path)
    end
  end

  defp parse_skill(frontmatter, body, path) do
    metadata = parse_frontmatter(frontmatter)
    requires = parse_requires(metadata["requires"])

    name =
      metadata["name"] ||
        path |> Path.dirname() |> Path.basename() ||
        Path.basename(path, ".md")

    content = String.trim(body)

    %{
      name: name,
      description: metadata["description"] || extract_first_paragraph(body),
      content: content,
      type: "markdown",
      code: content,
      parameters: normalize_parameters(metadata["parameters"]),
      disable_model_invocation: truthy?(metadata["disable-model-invocation"]),
      allowed_tools: normalize_allowed_tools(metadata["allowed-tools"]),
      user_invocable: metadata["user-invocable"] not in [false, "false"],
      always: truthy?(metadata["always"]),
      requires: requires,
      context: metadata["context"],
      agent: metadata["agent"],
      argument_hint: metadata["argument-hint"],
      path: path
    }
  end

  defp parse_requires(nil), do: %{}
  defp parse_requires(""), do: %{}

  defp parse_requires(requires) when is_binary(requires) do
    bins =
      requires
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.replace(&1, ~r/^env:/, ""))

    %{bins: bins, env: []}
  end

  defp parse_requires(requires) when is_map(requires) do
    %{
      bins: parse_list(requires["bins"] || requires[:bins]),
      env: parse_list(requires["env"] || requires[:env])
    }
  end

  defp parse_requires(_), do: %{}

  defp parse_list(nil), do: []
  defp parse_list(""), do: []
  defp parse_list(list) when is_list(list), do: list
  defp parse_list(str) when is_binary(str), do: String.split(str, ",") |> Enum.map(&String.trim/1)
  defp parse_list(_), do: []

  defp parse_frontmatter(""), do: %{}

  defp parse_frontmatter(content) do
    parse_yaml_block(String.split(content, "\n"), 0)
  end

  defp normalize_allowed_tools(nil), do: []
  defp normalize_allowed_tools(""), do: []
  defp normalize_allowed_tools(list) when is_list(list), do: list

  defp normalize_allowed_tools(string) when is_binary(string) do
    string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_allowed_tools(_), do: []

  defp normalize_parameters(params) when is_map(params), do: stringify_keys(params)
  defp normalize_parameters(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      value =
        if is_map(value) do
          stringify_keys(value)
        else
          value
        end

      {to_string(key), value}
    end)
  end

  defp truthy?(value) when value in [true, "true"], do: true
  defp truthy?(_), do: false

  defp extract_first_paragraph(""), do: ""

  defp extract_first_paragraph(body) do
    body
    |> String.split("\n\n")
    |> List.first()
    |> case do
      nil -> ""
      para -> para |> String.trim() |> String.slice(0..200)
    end
  end

  defp parse_yaml_block(lines, indent) do
    {result, _rest} = do_parse_yaml_block(lines, indent, %{})
    result
  end

  defp do_parse_yaml_block([], _indent, acc), do: {acc, []}

  defp do_parse_yaml_block([line | rest], indent, acc) do
    trimmed = String.trim(line)
    current_indent = indentation(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        do_parse_yaml_block(rest, indent, acc)

      current_indent < indent ->
        {acc, [line | rest]}

      String.starts_with?(trimmed, "- ") ->
        {acc, [line | rest]}

      true ->
        case String.split(trimmed, ":", parts: 2) do
          [key, ""] ->
            next_line = List.first(rest)

            {value, remaining} =
              cond do
                is_nil(next_line) or indentation(next_line) <= current_indent ->
                  {"", rest}

                String.starts_with?(String.trim(next_line), "- ") ->
                  parse_yaml_list(rest, current_indent + 2)

                true ->
                  do_parse_yaml_block(rest, current_indent + 2, %{})
              end

            do_parse_yaml_block(remaining, indent, Map.put(acc, key, value))

          [key, value] ->
            do_parse_yaml_block(rest, indent, Map.put(acc, key, parse_scalar(String.trim(value))))
        end
    end
  end

  defp parse_yaml_list(lines, indent), do: do_parse_yaml_list(lines, indent, [])

  defp do_parse_yaml_list([], _indent, acc), do: {Enum.reverse(acc), []}

  defp do_parse_yaml_list([line | rest], indent, acc) do
    trimmed = String.trim(line)
    current_indent = indentation(line)

    cond do
      trimmed == "" ->
        do_parse_yaml_list(rest, indent, acc)

      current_indent < indent or not String.starts_with?(trimmed, "- ") ->
        {Enum.reverse(acc), [line | rest]}

      true ->
        item =
          trimmed
          |> String.replace_prefix("- ", "")
          |> String.trim()
          |> parse_scalar()

        do_parse_yaml_list(rest, indent, [item | acc])
    end
  end

  defp indentation(line) do
    line
    |> String.length()
    |> Kernel.-(String.trim_leading(line) |> String.length())
  end

  defp parse_scalar("true"), do: true
  defp parse_scalar("false"), do: false
  defp parse_scalar("null"), do: nil

  defp parse_scalar(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        case Jason.decode(value) do
          {:ok, decoded} -> decoded
          _ -> value
        end

      true ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> value
        end
    end
  end

  defp find_executable(bin) do
    case :os.type() do
      {:win32, _} ->
        Enum.any?([bin, "#{bin}.exe", "#{bin}.cmd", "#{bin}.bat"], fn candidate ->
          System.find_executable(candidate) != nil
        end)

      _ ->
        System.find_executable(bin) != nil
    end
  end
end
