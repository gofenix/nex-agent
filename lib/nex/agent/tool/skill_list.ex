defmodule Nex.Agent.Tool.SkillList do
  @moduledoc """
  Skill List Tool - List available skills from skills.sh registry or locally installed
  """

  @behaviour Nex.Agent.Tool.Behaviour

  @api_url "https://skills.sh/api/search"
  @default_list_query ".."  # Search query that returns broad results for listing

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
    # Use search API with a broad query to get popular skills
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
    # Default to "all"
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
