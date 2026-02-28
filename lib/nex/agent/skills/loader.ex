defmodule Nex.Agent.Skills.Loader do
  @moduledoc """
  Skills loader - parses SKILL.md files following Claude Code format.

  ## SKILL.md Format

      ---
      name: explain-code
      description: Explains code with visual diagrams
      disable-model-invocation: false
      allowed-tools: Read, Grep
      ---
      
      When explaining code, always include:
      1. Start with an analogy
      2. Draw a diagram
  """

  @doc """
  Load skills from a directory.

  ## Examples

      skills = Nex.Agent.Skills.Loader.load_from_dir("~/.claude/skills")
  """
  @spec load_from_dir(String.t()) :: list(map())
  def load_from_dir(dir) do
    path = Path.expand(dir)

    if File.exists?(path) do
      path
      |> File.ls!()
      |> Enum.filter(fn name ->
        has_skill_md?(name) || has_skill_dir?(path, name)
      end)
      |> Enum.flat_map(fn name -> load_skill(name, path) end)
    else
      []
    end
  end

  @doc """
  Load all skills from standard locations:
  - ~/.nex/agent/skills (global)
  - .nex/skills (project)
  """
  @spec load_all() :: list(map())
  def load_all do
    global = Path.join(System.get_env("HOME", "~"), ".nex/agent/skills")
    project = ".nex/skills"

    []
    |> Kernel.++(load_from_dir(global))
    |> Kernel.++(load_from_dir(project))
    |> Enum.uniq_by(& &1[:name])
  end

  # Private functions

  defp has_skill_md?(name) do
    String.ends_with?(name, ".md")
  end

  defp has_skill_dir?(base_path, name) do
    File.dir?(Path.join(base_path, name))
  end

  defp load_skill(name, base_path) do
    skill_path = Path.join([base_path, name, "SKILL.md"])

    cond do
      File.dir?(Path.join(base_path, name)) && File.exists?(skill_path) ->
        # Directory with SKILL.md
        [parse_skill_file(skill_path, name)]

      File.exists?(skill_path) ->
        # Legacy: .md file (not a directory)
        [parse_skill_file(skill_path, name)]

      String.ends_with?(name, ".md") ->
        # Direct .md file
        direct_path = Path.join(base_path, name)
        [parse_skill_file(direct_path, Path.basename(name, ".md"))]

      true ->
        []
    end
  end

  defp parse_skill_file(path, _name) do
    content = File.read!(path)

    # Split by --- frontmatter delimiter (at start of line)
    case String.split(content, "\n---\n", parts: 2) do
      [frontmatter, body] ->
        parse_skill(frontmatter, body, path)

      [_] ->
        # No frontmatter, treat entire content as body
        parse_skill("", content, path)
    end
  end

  defp parse_skill(frontmatter, body, path) do
    metadata = parse_frontmatter(frontmatter)

    # Check for skill.json in the same directory
    skill_dir = Path.dirname(path)

    full_metadata =
      if File.exists?(Path.join(skill_dir, "skill.json")) do
        case File.read!(Path.join(skill_dir, "skill.json")) |> Jason.decode() do
          {:ok, json_meta} -> Map.merge(metadata, json_meta)
          _ -> metadata
        end
      else
        metadata
      end

    name =
      full_metadata["name"] ||
        Path.basename(path, "/SKILL.md") ||
        Path.basename(path, ".md")

    type = full_metadata["type"] || "markdown"

    # Load code based on type
    code =
      case type do
        "elixir" ->
          skill_ex = Path.join(skill_dir, "skill.ex")
          if File.exists?(skill_ex), do: File.read!(skill_ex), else: ""

        "script" ->
          script_file = Path.join(skill_dir, "script.sh")
          if File.exists?(script_file), do: File.read!(script_file), else: ""

        "mcp" ->
          mcp_file = Path.join(skill_dir, "mcp.json")
          if File.exists?(mcp_file), do: File.read!(mcp_file), else: ""

        _ ->
          String.trim(body)
      end

    %{
      name: name,
      description: full_metadata["description"] || extract_first_paragraph(body),
      content: code,
      type: type,
      code: code,
      parameters: full_metadata["parameters"] || %{},
      disable_model_invocation: full_metadata["disable-model-invocation"] == "true",
      allowed_tools: parse_allowed_tools(full_metadata["allowed-tools"]),
      user_invocable: full_metadata["user-invocable"] != "false",
      context: full_metadata["context"],
      agent: full_metadata["agent"],
      argument_hint: full_metadata["argument-hint"],
      path: path
    }
  end

  defp parse_frontmatter("") do
    %{}
  end

  defp parse_frontmatter(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> {String.trim(key), String.trim(value)}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp parse_allowed_tools(nil), do: []
  defp parse_allowed_tools(""), do: []

  defp parse_allowed_tools(string) do
    string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_first_paragraph("") do
    ""
  end

  defp extract_first_paragraph(body) do
    body
    |> String.split("\n\n")
    |> List.first()
    |> case do
      nil ->
        ""

      para ->
        para
        |> String.trim()
        |> String.slice(0..200)
    end
  end
end
