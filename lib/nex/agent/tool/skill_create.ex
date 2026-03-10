defmodule Nex.Agent.Tool.SkillCreate do
  @behaviour Nex.Agent.Tool.Behaviour
  alias Nex.Agent.Skills

  def name, do: "skill_create"
  def description, do: "Create a new reusable skill."
  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Skill name (snake_case)"},
          description: %{type: "string", description: "What this skill does"},
          content: %{type: "string", description: "Markdown skill content"}
        },
        required: ["name", "description", "content"]
      }
    }
  end

  def execute(%{"name" => name, "description" => description, "content" => content} = args, _ctx) do
    if Map.has_key?(args, "type") do
      {:error, "skill_create only supports Markdown skills. Implement code-based capabilities as tools."}
    else
      case Skills.create(%{name: name, description: description, content: content}) do
        {:ok, _} -> {:ok, "Skill '#{name}' created."}
        {:error, reason} -> {:error, "Error creating skill: #{inspect(reason)}"}
      end
    end
  end

  def execute(_args, _ctx), do: {:error, "name, description, and content are required"}
end
