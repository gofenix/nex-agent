defmodule Nex.Agent.Tool.SkillList do
  @moduledoc """
  Skill List Tool - List available skills from skills.sh registry or locally installed
  """

  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "skill_list"
  def description, do: "List available skills from skills.sh registry or locally installed skills"
  def category, do: :evolution

  def definition do
    %{
      name: "skill_list",
      description: "List available skills from skills.sh registry or locally installed skills",
      parameters: %{
        type: "object",
        properties: %{
          scope: %{
            type: "string",
            enum: ["registry", "local", "all"],
            description:
              "registry: from skills.sh leaderboard, local: installed skills, all: both",
            default: "all"
          }
        }
      }
    }
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
    case System.cmd("npx", ["skills", "list"], stderr_to_stdout: true, timeout: 30_000) do
      {output, 0} ->
        {:ok,
         %{
           skills: String.trim(output),
           message: "Registry skills listed successfully"
         }}

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

  def execute(_args, ctx), do: execute(%{"scope" => "all"}, ctx)
end
