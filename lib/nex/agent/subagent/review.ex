defmodule Nex.Agent.SubAgent.Review do
  @moduledoc """
  Performance review system for SubAgents.

  Tracks performance, analyzes patterns, and suggests code upgrade opportunities.
  """

  alias Nex.Agent.Memory

  @type performance_metric :: %{
          module: String.t(),
          task_type: String.t(),
          success: boolean(),
          duration_ms: integer(),
          tool_calls: [String.t()],
          user_feedback: String.t() | nil,
          timestamp: String.t()
        }

  @type review_suggestion :: %{
          module: atom(),
          current_version: String.t(),
          suggested_version: String.t(),
          reason: String.t(),
          changes: [String.t()],
          risk_level: :low | :medium | :high,
          proposed_code: String.t()
        }

  @doc """
  Record performance metrics for a SubAgent task execution.
  """
  @spec record_performance(atom(), map()) :: :ok
  def record_performance(subagent_module, metrics) do
    metric = %{
      module: to_string(subagent_module),
      task_type: Map.get(metrics, :task_type, "unknown"),
      success: Map.get(metrics, :success, true),
      duration_ms: Map.get(metrics, :duration_ms, 0),
      tool_calls: Map.get(metrics, :tool_calls, []),
      user_feedback: Map.get(metrics, :user_feedback),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Memory.append_history(
      "[#{String.slice(metric.timestamp, 0, 16)}] SUBAGENT_PERFORMANCE #{Jason.encode!(metric)}"
    )

    :ok
  end

  @doc """
  Analyze recent performance and generate review suggestions.
  """
  @spec self_reflect(atom(), keyword()) ::
          {:ok, review_suggestion()} | {:ok, nil} | {:error, String.t()}
  def self_reflect(subagent_module, opts \\ []) do
    window = Keyword.get(opts, :window, "7d")
    min_tasks = Keyword.get(opts, :min_tasks, 10)

    # Query recent performance data
    metrics = query_recent_metrics(subagent_module, window)

    if length(metrics) < min_tasks do
      # Not enough data
      {:ok, nil}
    else
      analysis = analyze_metrics(metrics)

      if should_suggest_upgrade?(analysis) do
        suggestion = generate_suggestion(subagent_module, analysis)
        {:ok, suggestion}
      else
        {:ok, nil}
      end
    end
  end

  @doc """
  Generate a human-readable performance review report.
  """
  @spec generate_report(review_suggestion()) :: String.t()
  def generate_report(suggestion) do
    """
    🤖 SubAgent Review Report
    ============================

    Module: #{suggestion.module}
    Current: #{suggestion.current_version} → Proposed: #{suggestion.suggested_version}

    📊 Reason:
    #{suggestion.reason}

    🔧 Suggested Changes:
    #{Enum.map_join(suggestion.changes, "\n", fn c -> "  - #{c}" end)}

    ⚠️  Risk Level: #{String.upcase(to_string(suggestion.risk_level))}

    💡 Proposed Code Preview:
    ```elixir
    #{String.slice(suggestion.proposed_code, 0, 500)}...
    ```

    To apply this code upgrade:
      mix nex.agent review_subagent report #{suggestion.module}
    """
  end

  # Private functions

  defp query_recent_metrics(module, window) do
    module_name = to_string(module)
    cutoff = parse_window(window)

    history_path()
    |> File.read()
    |> case do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_metric_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn metric ->
          metric.module == module_name and recent_enough?(metric.timestamp, cutoff)
        end)

      {:error, _} ->
        []
    end
  end

  defp analyze_metrics(metrics) do
    total = length(metrics)
    successes = Enum.count(metrics, & &1.success)
    success_rate = successes / total

    avg_duration =
      metrics
      |> Enum.map(& &1.duration_ms)
      |> Enum.sum()
      |> div(total)

    # Identify common failure patterns
    failure_patterns =
      metrics
      |> Enum.reject(& &1.success)
      |> Enum.group_by(& &1.task_type)
      |> Enum.map(fn {type, items} -> {type, length(items)} end)
      |> Enum.sort_by(fn {_, count} -> count end, :desc)

    # Identify tool usage patterns
    tool_usage =
      metrics
      |> Enum.flat_map(& &1.tool_calls)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, count} -> count end, :desc)

    %{
      total_tasks: total,
      success_rate: success_rate,
      avg_duration_ms: avg_duration,
      failure_patterns: failure_patterns,
      tool_usage: tool_usage,
      needs_improvement: success_rate < 0.9 or avg_duration > 30_000
    }
  end

  defp should_suggest_upgrade?(%{needs_improvement: true}), do: true
  defp should_suggest_upgrade?(%{success_rate: rate}) when rate < 0.95, do: true
  defp should_suggest_upgrade?(_), do: false

  defp generate_suggestion(module, analysis) do
    version = get_next_version(module)

    %{
      module: module,
      current_version: get_current_version(module),
      suggested_version: version,
      reason: generate_reason(analysis),
      changes: generate_changes(analysis),
      risk_level: assess_risk(analysis),
      proposed_code: generate_proposed_code(module, analysis)
    }
  end

  defp generate_reason(analysis) do
    cond do
      analysis.success_rate < 0.8 ->
        "Success rate (#{trunc(analysis.success_rate * 100)}%) below threshold. Need to improve error handling and edge cases."

      analysis.avg_duration_ms > 30_000 ->
        "Average task duration (#{div(analysis.avg_duration_ms, 1000)}s) too slow. Need to optimize tool usage and reduce LLM calls."

      true ->
        "General performance optimization opportunity detected."
    end
  end

  defp generate_changes(analysis) do
    changes = []

    changes =
      if analysis.success_rate < 0.9 do
        ["Add error handling for failed tool calls" | changes]
      else
        changes
      end

    changes =
      if analysis.avg_duration_ms > 30_000 do
        ["Optimize prompt to reduce token usage" | changes]
      else
        changes
      end

    changes =
      case analysis.failure_patterns do
        [{type, count} | _] when count > 2 ->
          ["Add specialized handling for '#{type}' tasks" | changes]

        _ ->
          changes
      end

    Enum.reverse(changes)
  end

  defp assess_risk(analysis) do
    cond do
      analysis.success_rate < 0.5 -> :high
      analysis.success_rate < 0.8 -> :medium
      true -> :low
    end
  end

  defp generate_proposed_code(_module, _analysis) do
    # This would generate actual improved code
    # For now, placeholder that references the need for evolution
    "# Proposed improvements based on performance analysis\n# See detailed report for specific changes"
  end

  defp get_current_version(module) do
    # Check if module has version info
    if function_exported?(module, :version, 0) do
      module.version()
    else
      "v1.0.0"
    end
  end

  defp get_next_version(module) do
    current = get_current_version(module)

    # Simple semver bump
    case Regex.run(~r/v(\d+)\.(\d+)\.(\d+)/, current) do
      [_, major, minor, patch] ->
        "v#{major}.#{minor}.#{String.to_integer(patch) + 1}"

      _ ->
        "v1.0.1"
    end
  end

  defp parse_metric_line(line) do
    case Regex.run(~r/^\[[^\]]+\]\s+SUBAGENT_PERFORMANCE\s+(.+)$/, line) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, metric} when is_map(metric) ->
            normalize_metric(metric)

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp normalize_metric(metric) do
    %{
      module: Map.get(metric, "module", ""),
      task_type: Map.get(metric, "task_type", "unknown"),
      success: Map.get(metric, "success", true),
      duration_ms: Map.get(metric, "duration_ms", 0),
      tool_calls: List.wrap(Map.get(metric, "tool_calls", [])),
      user_feedback: Map.get(metric, "user_feedback"),
      timestamp: Map.get(metric, "timestamp", "")
    }
  end

  defp recent_enough?(timestamp, cutoff) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> DateTime.compare(datetime, cutoff) in [:gt, :eq]
      _ -> false
    end
  end

  defp history_path do
    Path.join(Memory.workspace_path(), "memory/HISTORY.md")
  end

  defp parse_window("1d"), do: DateTime.add(DateTime.utc_now(), -86_400)
  defp parse_window("7d"), do: DateTime.add(DateTime.utc_now(), -604_800)
  defp parse_window("30d"), do: DateTime.add(DateTime.utc_now(), -2_592_000)
  defp parse_window(_), do: DateTime.add(DateTime.utc_now(), -604_800)
end
