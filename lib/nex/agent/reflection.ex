defmodule Nex.Agent.Reflection do
  alias Nex.Agent.Memory

  @moduledoc """
  Reflection layer for analyzing execution results and generating improvements.

  This is the core of the self-evolving agent. It:
  1. Analyzes execution results (success/failure patterns)
  2. Generates insights and learnings
  3. Can propose and apply improvements

  ## Usage

      # Analyze execution results
      analysis = Nex.Agent.Reflection.analyze(results)
      
      # Generate improvement suggestions
      suggestions = Nex.Agent.Reflection.suggest(analysis)
      
      # Apply improvements
      :ok = Nex.Agent.Reflection.apply(suggestion)
  """

  @doc """
  Analyze execution results and generate insights.

  ## Parameters

  * `results` - List of tool execution results
  * `opts` - Options

  ## Examples

      results = [
        %{tool: "bash", args: %{"command" => "mix test"}, result: "FAILURE", error: "..."},
        %{tool: "read", args: %{"path" => "mix.exs"}, result: "SUCCESS"}
      ]
      
      analysis = Nex.Agent.Reflection.analyze(results)
  """
  @spec analyze([map()], keyword()) :: map()
  def analyze(results, opts \\ []) do
    # Categorize results
    successes = Enum.filter(results, &(&1.result == "SUCCESS"))
    failures = Enum.filter(results, &(&1.result == "FAILURE"))

    # Analyze patterns
    error_patterns = analyze_errors(failures)
    success_patterns = analyze_successes(successes)

    # Generate insights
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

  @doc """
  Generate improvement suggestions based on analysis.
  """
  @spec suggest(map()) :: [map()]
  def suggest(analysis) do
    suggestions = []

    # Error-based suggestions
    suggestions =
      suggestions ++
        Enum.map(analysis.error_patterns, fn pattern ->
          %{
            type: :avoid_pattern,
            description: "Avoid: #{pattern.pattern}",
            reason: "Caused #{pattern.count} failures",
            action: "Don't use #{pattern.tool} with #{pattern.args_pattern}"
          }
        end)

    # Success-based suggestions  
    suggestions =
      suggestions ++
        Enum.map(analysis.success_patterns, fn pattern ->
          %{
            type: :reinforce_pattern,
            description: "Good: #{pattern.pattern}",
            reason: "Led to #{pattern.count} successes",
            action: "Continue using #{pattern.tool} with #{pattern.args_pattern}"
          }
        end)

    # Learning suggestions
    if analysis.failures > analysis.successes do
      suggestions =
        suggestions ++
          [
            %{
              type: :strategy_change,
              description: "More failures than successes",
              reason: "Consider trying a different approach",
              action: "Analyze root cause and adjust strategy"
            }
          ]
    end

    suggestions
  end

  @doc """
  Apply a suggested improvement.

  ## Types of improvements

  * `:memory` - Add to memory
  * `:strategy` - Adjust strategy
  * `:skill` - Create/modify skill
  * `:prompt` - Modify system prompt
  """
  @spec apply(map()) :: :ok | {:error, String.t()}
  def apply(suggestion) do
    case suggestion.type do
      :avoid_pattern ->
        # Add to memory to avoid
        Memory.append(
          "Learning: #{suggestion.description}",
          "LEARNING",
          %{type: :avoid, suggestion: suggestion.action}
        )

      :reinforce_pattern ->
        # Add to memory as good pattern
        Memory.append(
          "Learning: #{suggestion.description}",
          "LEARNING",
          %{type: :reinforce, suggestion: suggestion.action}
        )

      :strategy_change ->
        # Log for future strategy adjustment
        Memory.append(
          "Strategy: #{suggestion.description}",
          "STRATEGY",
          %{type: :strategy, suggestion: suggestion.action}
        )

      _ ->
        {:error, "Unknown suggestion type: #{suggestion.type}"}
    end
  end

  @doc """
  Full reflection cycle: analyze, suggest, and optionally apply.
  """
  @spec reflect([map()], keyword()) :: map()
  def reflect(results, opts \\ []) do
    auto_apply = Keyword.get(opts, :auto_apply, false)

    analysis = analyze(results, opts)
    suggestions = suggest(analysis)

    if auto_apply do
      Enum.each(suggestions, &apply/1)
    end

    %{
      analysis: analysis,
      suggestions: suggestions,
      applied: auto_apply
    }
  end

  # Private functions

  defp analyze_errors(failures) do
    failures
    |> Enum.group_by(fn f ->
      "#{f.tool}:#{Map.get(f.args, "command", Map.get(f.args, "path", "unknown"))}"
    end)
    |> Enum.map(fn {pattern, items} ->
      %{
        pattern: pattern,
        count: length(items),
        tool: hd(items).tool,
        args_pattern: extract_key_args(hd(items).args),
        errors: Enum.map(items, & &1.error)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp analyze_successes(successes) do
    successes
    |> Enum.group_by(fn f ->
      "#{f.tool}:#{Map.get(f.args, "command", Map.get(f.args, "path", "unknown"))}"
    end)
    |> Enum.map(fn {pattern, items} ->
      %{
        pattern: pattern,
        count: length(items),
        tool: hd(items).tool,
        args_pattern: extract_key_args(hd(items).args)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp extract_key_args(args) when is_map(args) do
    args
    |> Map.take(["command", "path", "query"])
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(",")
  end

  defp extract_key_args(_), do: "unknown"

  defp generate_insights(error_patterns, success_patterns) do
    insights = []

    # If same tool keeps failing
    if length(error_patterns) > 0 && hd(error_patterns).count > 3 do
      insights = insights ++ ["#{hd(error_patterns).tool} seems problematic"]
    end

    # If success pattern is strong
    if length(success_patterns) > 0 && hd(success_patterns).count > 5 do
      insights = insights ++ ["#{hd(success_patterns).tool} is reliable"]
    end

    insights
  end
end
