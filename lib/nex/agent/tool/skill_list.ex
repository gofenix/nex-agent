defmodule Nex.Agent.Tool.SkillList do
  @moduledoc """
  Skill List Tool - list locally installed Markdown skills for inventory and compatibility.
  """

  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "skill_list"

  def description do
    """
    List locally installed Markdown skills for local inventory. Prefer `skill_discover` for skill discovery.
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
          }
        }
      }
    }
  end

  # Backward-compatible read path; prefer the dedicated skill_read tool.
  def execute(%{"detail" => skill_name}, ctx) when is_binary(skill_name) and skill_name != "" do
    Nex.Agent.Tool.SkillRead.execute(%{"name" => skill_name}, ctx)
  end

  def execute(%{"scope" => "local"}, ctx) do
    skills = Nex.Agent.Skills.list(workspace_opts(ctx))

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

  defp workspace_opts(%{workspace: workspace}) when is_binary(workspace),
    do: [workspace: workspace]

  defp workspace_opts(_ctx), do: []
end
