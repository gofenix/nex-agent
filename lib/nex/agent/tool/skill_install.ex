defmodule Nex.Agent.Tool.SkillInstall do
  @moduledoc """
  Skill Install Tool - Install skills from GitHub to ~/.nex/agent/skills/
  """

  @behaviour Nex.Agent.Tool.Behaviour
  alias Nex.Agent.Skills

  def name, do: "skill_install"
  def description do
    """
    Install a skill from GitHub. After installation, check 'how_to_use' in result for usage instructions.
    
    **Post-install steps**:
    1. Result includes skill name, type, and usage instructions
    2. Elixir skills: call skill_<name>(%{"input" => "..."})
    3. Markdown skills: usually CLI tools, use via bash
    4. MCP skills: MCP tools will be available after use
    
    **Usage**: skill_install(source="owner/repo")
    """
  end
  def category, do: :evolution

  @skills_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace/skills")
  @github_raw "https://raw.githubusercontent.com"

  def definition do
    %{
      name: "skill_install",
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          source: %{type: "string", description: "GitHub repo (owner/repo)"},
          skill: %{type: "string", description: "Specific skill name (optional)"},
          force: %{type: "boolean", description: "Force overwrite", default: false}
        },
        required: ["source"]
      }
    }
  end

  def execute(%{"source" => source} = args, _ctx) do
    with {:ok, owner, repo} <- parse_source(source),
         {:ok, installed} <- install_from_repo(owner, repo, args),
         :ok <- Skills.reload() do
      
      # Get detailed information including usage guide
      skill_details = Enum.map(installed, fn skill_name ->
        skill = Skills.get(skill_name)
        if skill do
          %{
            name: skill_name,
            type: skill.type,
            description: skill.description,
            how_to_use: generate_usage_guide(skill)
          }
        else
          %{name: skill_name, type: "unknown", description: "", how_to_use: "Skill not found after installation"}
        end
      end)
      
      {:ok, %{
        status: "installed", 
        skills: skill_details, 
        count: length(skill_details),
        message: "Installed #{length(skill_details)} skill(s). Check 'how_to_use' for usage instructions."
      }}
    end
  end
  defp parse_source(source) do
    case String.split(source, "/", parts: 2) do
      [owner, repo] -> {:ok, owner, repo}
      _ -> {:error, "Invalid format. Use 'owner/repo'"}
    end
  end

  defp install_from_repo(owner, repo, args) do
    skill_dirs = ["skills", ".agents/skills", ".claude/skills", ""]

    installed =
      skill_dirs
      |> Enum.flat_map(fn dir ->
        case find_skills_in_dir(owner, repo, dir) do
          {:ok, skills} -> skills
          _ -> []
        end
      end)
      |> Enum.filter(fn skill ->
        case args["skill"] do
          nil -> true
          name -> String.contains?(String.downcase(skill), String.downcase(name))
        end
      end)
      |> Enum.map(fn skill_path ->
        install_skill(owner, repo, skill_path, args["force"] || false)
      end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, name} -> name end)

    if installed == [] do
      {:error, "No skills found"}
    else
      {:ok, installed}
    end
  end

  defp find_skills_in_dir(owner, repo, dir) do
    url = "#{@github_raw}/#{owner}/#{repo}/main/#{dir}/SKILL.md"

    case Req.get(url, headers: github_headers(), receive_timeout: 10_000) do
      {:ok, %{status: 200}} ->
        {:ok, [if(dir == "", do: ".", else: dir)]}

      _ ->
        api_url = "https://api.github.com/repos/#{owner}/#{repo}/contents/#{dir}"

        case Req.get(api_url, headers: github_headers(), receive_timeout: 10_000) do
          {:ok, %{status: 200, body: items}} when is_list(items) ->
            skill_dirs =
              items
              |> Enum.filter(fn item ->
                item["type"] == "dir" or item["name"] == "SKILL.md"
              end)
              |> Enum.map(fn item ->
                if item["name"] == "SKILL.md" do
                  dir
                else
                  Path.join(dir, item["name"])
                end
              end)

            {:ok, skill_dirs}

          _ ->
            {:error, :not_found}
        end
    end
  end

  defp install_skill(owner, repo, skill_path, force) do
    skill_name = Path.basename(skill_path) |> String.downcase()
    dest_dir = Path.join(@skills_dir, skill_name)

    if File.exists?(dest_dir) and not force do
      {:error, "Already exists"}
    else
      if File.exists?(dest_dir), do: File.rm_rf!(dest_dir)
      File.mkdir_p!(dest_dir)

      skill_md_url = "#{@github_raw}/#{owner}/#{repo}/main/#{skill_path}/SKILL.md"

      case Req.get(skill_md_url, headers: github_headers(), receive_timeout: 15_000) do
        {:ok, %{status: 200, body: content}} ->
          File.write!(Path.join(dest_dir, "SKILL.md"), content)

          optional = ["skill.ex", "script.sh", "mcp.json", "skill.json"]

          Enum.each(optional, fn file ->
            url = "#{@github_raw}/#{owner}/#{repo}/main/#{skill_path}/#{file}"

            case Req.get(url, headers: github_headers(), receive_timeout: 5_000) do
              {:ok, %{status: 200, body: data}} ->
                File.write!(Path.join(dest_dir, file), data)

              _ ->
                :ok
            end
          end)

          {:ok, skill_name}

        _ ->
          File.rm_rf!(dest_dir)
          {:error, "Failed to download SKILL.md"}
      end
    end
  end

  defp github_headers do
    token = System.get_env("GITHUB_TOKEN")
    base = [{"Accept", "application/vnd.github.v3+json"}]
    if token && token != "", do: [{"Authorization", "token #{token}"} | base], else: base
  end

  # Helper functions for generating usage guide
  
  defp generate_usage_guide(skill) do
    case skill[:type] do
      "elixir" ->
        sanitized = skill[:name] |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
        "Elixir skill. Call directly: skill_#{sanitized}(%{\"input\" => \"your input\"})"
      
      "markdown" ->
        cli_name = extract_cli_name(skill)
        if cli_name do
          "Markdown skill with CLI. Use via bash: bash(\"#{cli_name} <command>\")\n" <>
          "Read full instructions: skill_list(detail=\"#{skill[:name]}\")"
        else
          "Markdown skill. Read SKILL.md first: skill_list(detail=\"#{skill[:name]}\")"
        end
      
      "mcp" ->
        "MCP skill. MCP tools will be available after calling this skill.\n" <>
        "Read details: skill_list(detail=\"#{skill[:name]}\")"
      
      _ ->
        "Unknown skill type. Read SKILL.md: skill_list(detail=\"#{skill[:name]}\")"
    end
  end
  
  defp extract_cli_name(skill) do
    allowed = skill[:allowed_tools] || []
    bash_tool = Enum.find(allowed, fn tool ->
      String.starts_with?(to_string(tool), "Bash(")
    end)
    
    if bash_tool do
      bash_tool
      |> to_string()
      |> String.replace("Bash(", "")
      |> String.replace(~r/:\*\)$/, "")
      |> String.replace(")", "")
      |> String.trim()
    else
      nil
    end
  end
end
