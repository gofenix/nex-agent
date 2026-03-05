defmodule Nex.Agent.Tool.SkillInstall do
  @moduledoc """
  Skill Install Tool - Install skills from GitHub to ~/.nex/agent/skills/
  """

  @behaviour Nex.Agent.Tool.Behaviour
  require Logger
  alias Nex.Agent.Skills

  def name, do: "skill_install"
  def description, do: "Install a skill from GitHub (e.g., 'owner/repo'). Downloads to ~/.nex/agent/skills/"
  def category, do: :evolution

  @skills_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/skills")
  @github_raw "https://raw.githubusercontent.com"

  def definition do
    %{
      name: "skill_install",
      description:
        "Install a skill from GitHub (e.g., 'owner/repo'). Downloads to ~/.nex/agent/skills/",
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
      {:ok, %{status: "installed", skills: installed, count: length(installed)}}
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
end
