defmodule Nex.Agent.Tool.SkillSearch do
  @moduledoc """
  Skill Search Tool - Search for skills on skills.sh registry via HTTP API
  """

  @behaviour Nex.Agent.Tool.Behaviour
  require Logger

  @api_url "https://skills.sh/api/search"

  def name, do: "skill_search"
  def description, do: "Search for skills on skills.sh registry by keyword or topic"
  def category, do: :evolution

  def definition do
    %{
      name: "skill_search",
      description: "Search for skills on skills.sh registry by keyword or topic",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "Search query (e.g., 'react', 'typescript', 'testing')"
          }
        },
        required: ["query"]
      }
    }
  end

  def execute(%{"query" => query}, _ctx) do
    # Query must be at least 2 characters for skills.sh API
    query = if String.length(query) < 2, do: query <> "*", else: query

    url = "#{@api_url}?q=#{URI.encode_www_form(query)}"

    case System.cmd("curl", ["-s", "-L", "--max-time", "30", url],
            stderr_to_stdout: true
          ) do
      {output, 0} ->
        parse_api_response(output, query)

      {error, exit_code} ->
        {:error, "API request failed (exit #{exit_code}): #{error}"}
    end
  end

  defp parse_api_response(output, query) do
    case Jason.decode(output) do
      {:ok, %{"skills" => skills}} when is_list(skills) ->
        results = Enum.map(skills, &format_skill/1)

        {:ok,
         %{
           query: query,
           results: results,
           count: length(results),
           message: "Found #{length(results)} skill(s) matching '#{query}'"
         }}

      {:ok, %{"error" => error}} ->
        {:error, "API error: #{error}"}

      {:error, _} ->
        {:error, "Failed to parse API response"}
    end
  end

  defp format_skill(skill) do
    %{
      id: skill["id"],
      skill_id: skill["skillId"],
      name: skill["name"],
      source: skill["source"],
      installs: skill["installs"]
    }
  end
end
