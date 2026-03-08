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
          content: %{type: "string", description: "Skill content (markdown instructions or script code)"},
          type: %{
            type: "string",
            enum: ["markdown", "script", "elixir"],
            description: "Skill type: 'markdown' for instructions, 'script' for bash scripts, 'elixir' for Elixir modules"
          }
        },
        required: ["name", "description", "content"]
      }
    }
  end

  def execute(%{"name" => name, "description" => description, "content" => content} = args, _ctx) do
    skill_type = case args["type"] do
      "script" -> "script"
      "elixir" -> "elixir"
      _ -> "markdown"
    end

    content_key = if skill_type in ["script", "elixir"], do: :code, else: :content

    attrs =
      %{name: name, description: description, type: skill_type}
      |> Map.put(content_key, content)

    case Skills.create(attrs) do
      {:ok, _} -> {:ok, "Skill '#{name}' created (type: #{skill_type})."}
      {:error, reason} -> {:error, "Error creating skill: #{inspect(reason)}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "name, description, and content are required"}
end
