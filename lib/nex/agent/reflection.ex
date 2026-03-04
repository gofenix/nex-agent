defmodule Nex.Agent.Reflection do
  @moduledoc """
  LLM-driven reflection layer for analyzing execution results and generating improvements.

  This is the core of the self-evolving agent. It:
  1. Collects tool execution results from the Bus
  2. Uses an LLM to analyze patterns and generate structured suggestions
  3. Can auto-apply improvements (new skills, soul updates, memory entries)

  ## Usage

      # LLM-driven reflection on recent tool results
      {:ok, result} = Nex.Agent.Reflection.reflect_llm(tool_results, opts)

      # Fast rule-based fallback
      analysis = Nex.Agent.Reflection.analyze(results)
      suggestions = Nex.Agent.Reflection.suggest(analysis)

      # Full cycle: analyze, suggest, apply
      result = Nex.Agent.Reflection.reflect(results, auto_apply: true)
  """

  require Logger

  alias Nex.Agent.{Memory, Skills, Runner}

  @max_results_for_llm 50
  @reflection_tool_name "reflection_suggestions"

  # --- LLM-driven reflection ---

  @doc """
  Run LLM-driven reflection on a list of tool results.

  Returns structured suggestions: `:new_skill`, `:soul_update`, `:memory_entry`, `:strategy_change`.

  ## Options

  * `:provider` - LLM provider
  * `:model` - LLM model
  * `:api_key` - API key
  * `:base_url` - API base URL
  * `:auto_apply` - automatically apply suggestions (default false)
  """
  @spec reflect_llm([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def reflect_llm(tool_results, opts \\ []) do
    auto_apply = Keyword.get(opts, :auto_apply, false)

    results_summary = build_results_summary(tool_results)
    memory_snippet = Memory.read_long_term() |> truncate(500)
    skills_list = Skills.list() |> Enum.map(& &1.name) |> Enum.join(", ")

    messages = [
      %{
        "role" => "system",
        "content" => reflection_system_prompt()
      },
      %{
        "role" => "user",
        "content" => """
        ## Recent Tool Execution Results (#{length(tool_results)} total)

        #{results_summary}

        ## Current Long-term Memory (excerpt)
        #{memory_snippet}

        ## Existing Skills
        #{skills_list}

        Analyze these results and call the `#{@reflection_tool_name}` tool with your structured suggestions.
        """
      }
    ]

    tools = [reflection_tool_schema()]

    case Runner.call_llm_for_consolidation(messages, Keyword.put(opts, :tools, tools)) do
      {:ok, args} ->
        suggestions = parse_suggestions(args)
        Logger.info("[Reflection] LLM generated #{length(suggestions)} suggestion(s)")

        if auto_apply do
          Enum.each(suggestions, &apply_suggestion/1)
        end

        {:ok, %{suggestions: suggestions, applied: auto_apply, source: :llm}}

      {:error, reason} ->
        Logger.warning("[Reflection] LLM reflection failed: #{inspect(reason)}, using rule-based")
        result = reflect(tool_results, opts)
        {:ok, Map.put(result, :source, :rule_based)}
    end
  end

  # --- Rule-based reflection (fast fallback) ---

  @spec analyze([map()], keyword()) :: map()
  def analyze(results, _opts \\ []) do
    successes = Enum.filter(results, &tool_succeeded?/1)
    failures = Enum.filter(results, &(not tool_succeeded?(&1)))

    error_patterns = analyze_patterns(failures)
    success_patterns = analyze_patterns(successes)
    insights = generate_insights(error_patterns, success_patterns)

    %{
      total: length(results),
      successes: length(successes),
      failures: length(failures),
      error_patterns: error_patterns,
      success_patterns: success_patterns,
      insights: insights,
      timestamp: DateTime.utc_now() |> DateTime.to_string()
    }
  end

  @spec suggest(map()) :: [map()]
  def suggest(analysis) do
    error_suggestions =
      Enum.map(analysis.error_patterns, fn pattern ->
        %{
          type: :avoid_pattern,
          description: "Avoid: #{pattern.pattern}",
          reason: "Caused #{pattern.count} failures",
          action: "Don't use #{pattern.tool} with #{pattern.args_pattern}"
        }
      end)

    success_suggestions =
      Enum.map(analysis.success_patterns, fn pattern ->
        %{
          type: :reinforce_pattern,
          description: "Good: #{pattern.pattern}",
          reason: "Led to #{pattern.count} successes",
          action: "Continue using #{pattern.tool} with #{pattern.args_pattern}"
        }
      end)

    strategy_suggestions =
      if analysis.failures > analysis.successes do
        [
          %{
            type: :strategy_change,
            description: "More failures than successes",
            reason: "Consider trying a different approach",
            action: "Analyze root cause and adjust strategy"
          }
        ]
      else
        []
      end

    error_suggestions ++ success_suggestions ++ strategy_suggestions
  end

  @spec apply_suggestion(map()) :: :ok | {:error, String.t()}
  def apply_suggestion(%{type: :new_skill} = s) do
    case Skills.create(%{
           name: s[:name] || "auto_skill",
           description: s[:description] || s.action,
           type: :markdown,
           content: s[:content] || s.action
         }) do
      r when r in [:ok] -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "Skill creation failed: #{inspect(reason)}"}
    end
  end

  def apply_suggestion(%{type: :soul_update} = s) do
    soul_path = Path.join([System.get_env("HOME", "."), ".nex", "agent", "workspace", "SOUL.md"])
    File.mkdir_p!(Path.dirname(soul_path))

    current = case File.read(soul_path) do
      {:ok, c} -> c
      _ -> ""
    end

    new_content = current <> "\n\n## Auto-learned (#{Date.utc_today()})\n#{s.action}\n"
    File.write(soul_path, new_content)
  end

  def apply_suggestion(%{type: :memory_entry} = s) do
    Memory.append(
      "Reflection: #{s.description || s.action}",
      "REFLECTION",
      %{type: :reflection, suggestion: s.action}
    )
  end

  def apply_suggestion(%{type: type} = s) when type in [:avoid_pattern, :reinforce_pattern, :strategy_change] do
    Memory.append(
      "Learning: #{s.description}",
      "LEARNING",
      %{type: type, suggestion: s.action}
    )
  end

  def apply_suggestion(%{type: type}) do
    {:error, "Unknown suggestion type: #{type}"}
  end

  @spec reflect([map()], keyword()) :: map()
  def reflect(results, opts \\ []) do
    auto_apply = Keyword.get(opts, :auto_apply, false)

    analysis = analyze(results, opts)
    suggestions = suggest(analysis)

    if auto_apply do
      Enum.each(suggestions, &apply_suggestion/1)
    end

    %{analysis: analysis, suggestions: suggestions, applied: auto_apply}
  end

  # --- Private: LLM helpers ---

  defp reflection_system_prompt do
    """
    You are an agent reflection system. Analyze the provided tool execution results and generate structured improvement suggestions.

    You MUST call the `#{@reflection_tool_name}` tool with a JSON array of suggestions. Each suggestion should have:
    - "type": one of "new_skill", "soul_update", "memory_entry", "strategy_change"
    - "description": what you observed
    - "action": specific actionable improvement
    - "name": (for new_skill only) snake_case skill name
    - "content": (for new_skill only) the skill content

    Focus on:
    1. Repeated failure patterns → suggest new skills or strategy changes
    2. Successful patterns worth reinforcing → memory entries
    3. Behavioral adjustments → soul_update (use sparingly)
    4. Automatable sequences → new_skill

    Be concise. Only suggest genuinely useful improvements.
    """
  end

  defp reflection_tool_schema do
    %{
      "name" => @reflection_tool_name,
      "description" => "Submit structured improvement suggestions based on reflection analysis.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "suggestions" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "type" => %{"type" => "string", "enum" => ["new_skill", "soul_update", "memory_entry", "strategy_change"]},
                "description" => %{"type" => "string"},
                "action" => %{"type" => "string"},
                "name" => %{"type" => "string"},
                "content" => %{"type" => "string"}
              },
              "required" => ["type", "description", "action"]
            }
          }
        },
        "required" => ["suggestions"]
      }
    }
  end

  defp build_results_summary(results) do
    results
    |> Enum.take(@max_results_for_llm)
    |> Enum.map_join("\n", fn r ->
      tool = Map.get(r, :tool) || Map.get(r, "tool") || "?"
      success = Map.get(r, :success) || Map.get(r, "success")
      result_preview = Map.get(r, :result) || Map.get(r, "result") || ""
      result_preview = truncate(to_string(result_preview), 100)
      status = if success, do: "OK", else: "FAIL"
      "- [#{status}] #{tool}: #{result_preview}"
    end)
  end

  defp parse_suggestions(%{"suggestions" => suggestions}) when is_list(suggestions) do
    Enum.map(suggestions, fn s ->
      %{
        type: String.to_atom(s["type"] || "memory_entry"),
        description: s["description"] || "",
        action: s["action"] || "",
        name: s["name"],
        content: s["content"]
      }
    end)
  end

  defp parse_suggestions(_), do: []

  # --- Private: rule-based helpers ---

  defp tool_succeeded?(%{success: true}), do: true
  defp tool_succeeded?(%{"success" => true}), do: true
  defp tool_succeeded?(%{result: r}) when is_binary(r), do: not String.starts_with?(r, "Error")
  defp tool_succeeded?(%{"result" => r}) when is_binary(r), do: not String.starts_with?(r, "Error")
  defp tool_succeeded?(_), do: false

  defp analyze_patterns(items) do
    items
    |> Enum.group_by(fn item ->
      tool = Map.get(item, :tool) || Map.get(item, "tool") || "?"
      "#{tool}"
    end)
    |> Enum.map(fn {pattern, group} ->
      tool = Map.get(hd(group), :tool) || Map.get(hd(group), "tool") || "?"
      %{pattern: pattern, count: length(group), tool: tool, args_pattern: pattern}
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp generate_insights(error_patterns, success_patterns) do
    err_insights =
      if length(error_patterns) > 0 && hd(error_patterns).count > 3 do
        ["#{hd(error_patterns).tool} seems problematic"]
      else
        []
      end

    succ_insights =
      if length(success_patterns) > 0 && hd(success_patterns).count > 5 do
        ["#{hd(success_patterns).tool} is reliable"]
      else
        []
      end

    err_insights ++ succ_insights
  end

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end

  defp truncate(str, _max) when is_binary(str), do: str
  defp truncate(nil, _max), do: ""
  defp truncate(other, max), do: truncate(inspect(other), max)
end
