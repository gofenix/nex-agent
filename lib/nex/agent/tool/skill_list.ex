defmodule Nex.Agent.Tool.SkillList do
  @moduledoc """
  Skill List Tool - list available local Markdown skills.
  """

  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "skill_list"

  def description do
    """
    List local Markdown skills or read a skill's SKILL.md content.

    Parameters:
    - scope=local: list installed skills
    - detail=<name>: read full SKILL.md for that skill
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
            enum: ["local"],
            description: "List locally installed skills",
            default: "local"
          },
          detail: %{
            type: "string",
            description:
              "Skill name to read full content (e.g. 'code-review'). Returns the complete SKILL.md file."
          }
        }
      }
    }
  end

  def execute(%{"detail" => skill_name}, _ctx) when is_binary(skill_name) and skill_name != "" do
    path = Path.join([skills_dir(), skill_name, "SKILL.md"])

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
      |> Enum.map_join("\n", fn skill ->
        "- #{skill.name}: #{skill.description}"
      end)

    {:ok,
     %{
       count: length(skills),
       skills: formatted,
       message: "Found #{length(skills)} locally installed skill(s)"
     }}
  end

  def execute(_args, ctx) do
    execute(%{"scope" => "local"}, ctx)
  end

  defp skills_dir do
    workspace =
      Application.get_env(
        :nex_agent,
        :workspace_path,
        Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")
      )

    Path.join(workspace, "skills")
  end
end
