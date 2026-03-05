defmodule Nex.Agent.Tool.SkillSearch do
  @moduledoc """
  Skill Search Tool - Search for skills on skills.sh registry
  """

  @behaviour Nex.Agent.Tool.Behaviour

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
    case System.cmd("npx", ["skills", "find", query], stderr_to_stdout: true, timeout: 30_000) do
      {output, 0} ->
        results = parse_search_results(output)

        {:ok,
         %{
           query: query,
           results: results,
           count: length(results),
           message: "Found #{length(results)} skill(s) matching '#{query}'"
         }}

      {error, exit_code} ->
        # Fallback: try to provide helpful error message
        {:error,
         "Search failed (exit #{exit_code}). Note: npx skills find may require interactive mode. Error: #{error}"}
    end
  end

  defp parse_search_results(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&filter_skill_line/1)
    |> Enum.map(&format_skill_result/1)
    |> Enum.reject(&is_nil/1)
  end

  defp filter_skill_line(line) do
    line = String.trim(line)
    # Filter out empty lines and common non-skill lines
    line != "" and
      not String.starts_with?(line, ">") and
      not String.starts_with?(line, "#") and
      String.contains?(line, "/")
  end

  defp format_skill_result(line) do
    line = String.trim(line)

    # Try to extract owner/repo format
    case Regex.run(~r/([\w-]+\/[\w-]+)/, line) do
      [_, source] ->
        %{
          source: source,
          description: extract_description(line, source)
        }

      _ ->
        # If doesn't match pattern, return as-is if it looks like a skill reference
        if String.length(line) > 0 and String.length(line) < 200 do
          %{source: line, description: ""}
        else
          nil
        end
    end
  end

  defp extract_description(line, source) do
    line
    |> String.replace(source, "")
    |> String.trim()
    |> String.trim("-")
    |> String.trim()
  end
end
