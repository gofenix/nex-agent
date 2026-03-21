defmodule Nex.Agent.Tool.SkillRead do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "skill_read"

  def description do
    "Read a specific local Markdown skill so the main agent loop can load it on demand."
  end

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          name: %{
            type: "string",
            description: "Skill name to read, for example `code-review`"
          }
        },
        required: ["name"]
      }
    }
  end

  def execute(%{"name" => skill_name}, ctx) when is_binary(skill_name) do
    case Nex.Agent.Skills.get(skill_name, workspace_opts(ctx)) do
      nil ->
        {:error, "Skill '#{skill_name}' not found"}

      skill ->
        path = Map.get(skill, :path) || Map.get(skill, "path")

        case File.read(path) do
          {:ok, content} ->
            {:ok,
             %{
               "name" => skill_name,
               "content" => content,
               "message" => "Loaded skill '#{skill_name}'"
             }}

          {:error, reason} ->
            {:error, "Failed to read skill '#{skill_name}': #{inspect(reason)}"}
        end
    end
  end

  def execute(_args, _ctx), do: {:error, "name is required"}

  defp workspace_opts(%{workspace: workspace}) when is_binary(workspace),
    do: [workspace: workspace]

  defp workspace_opts(_ctx), do: []
end
