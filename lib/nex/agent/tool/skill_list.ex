defmodule Nex.Agent.Tool.SkillList do
  @moduledoc """
  Skill List Tool - List available skills from skills.sh registry or locally installed
  """

  @behaviour Nex.Agent.Tool.Behaviour

  @api_url "https://skills.sh/api/search"
  @default_list_query ".."
  @skills_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace/skills")

  def name, do: "skill_list"

  def description do
    """
    **FIRST STEP**: List or inspect available skills. ALWAYS call this BEFORE skill_search.
    
    **Decision Flow**:
    1. Call skill_list(scope=local) to check installed skills
    2. If found → use it directly or read detail
    3. If not found → then use skill_search
    
    **Parameters**:
    - scope=local: List installed skills (CHECK THIS FIRST!)
    - scope=registry: Browse popular skills on skills.sh
    - detail=<name>: Read full SKILL.md to learn how to use a skill
    """
  end

  def category, do: :evolution

  def definition do
    %{
      name: "skill_list",
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          scope: %{
            type: "string",
            enum: ["registry", "local", "all"],
            description:
              "registry: from skills.sh leaderboard, local: installed skills, all: both",
            default: "all"
          },
          detail: %{
            type: "string",
            description: "Skill name to read full content (e.g. 'busydog'). Returns the complete SKILL.md file."
          }
        }
      }
    }
  end

  def execute(%{"detail" => skill_name}, _ctx) when is_binary(skill_name) and skill_name != "" do
    path = Path.join([@skills_dir, skill_name, "SKILL.md"])

    case File.read(path) do
      {:ok, content} ->
        {:ok, %{name: skill_name, content: content, message: "Skill '#{skill_name}' content"}}

      {:error, :enoent} ->
        {:error, "Skill '#{skill_name}' not found at #{path}"}
    end
  end

  def execute(%{"scope" => "local"}, _ctx) do
    skills = Nex.Agent.Skills.list()

    formatted =
      skills
      |> Enum.map(fn skill ->
        "- #{skill.name}: #{skill.description}"
      end)
      |> Enum.join("\n")

    {:ok,
     %{
       count: length(skills),
       skills: formatted,
       message: "Found #{length(skills)} locally installed skill(s)"
     }}
  end

  def execute(%{"scope" => "registry"}, _ctx) do
    url = "#{@api_url}?q=#{@default_list_query}"

    case System.cmd("curl", ["-s", "-L", url], stderr_to_stdout: true) do
      {output, 0} ->
        parse_registry_response(output)

      {error, exit_code} ->
        {:error, "Failed to list registry skills (exit #{exit_code}): #{error}"}
    end
  end

  def execute(%{"scope" => "all"}, ctx) do
    {:ok, local_result} = execute(%{"scope" => "local"}, ctx)
    {:ok, registry_result} = execute(%{"scope" => "registry"}, ctx)

    {:ok,
     %{
       local: local_result,
       registry: registry_result,
       message: "Listed both local and registry skills"
     }}
  end

  def execute(_args, ctx) do
    execute(%{"scope" => "all"}, ctx)
  end

  defp parse_registry_response(output) do
    case Jason.decode(output) do
      {:ok, %{"skills" => skills}} when is_list(skills) ->
        formatted =
          skills
          |> Enum.map(fn skill ->
            "- #{skill["source"]}: #{skill["name"]} (#{skill["installs"]} installs)"
          end)
          |> Enum.join("\n")

        {:ok,
         %{
           skills: formatted,
           message: "Registry skills listed successfully"
         }}

      {:ok, %{"error" => error}} ->
        {:error, "API error: #{error}"}

      {:error, _} ->
        {:error, "Failed to parse registry response"}
    end
  end
end
