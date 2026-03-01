defmodule Nex.Agent.Evaluation do
  @moduledoc """
  Lightweight evaluation and gating utilities for autonomous evolution.
  """

  alias Nex.Agent.Memory

  @type metrics :: %{
          total: non_neg_integer(),
          success: non_neg_integer(),
          failure: non_neg_integer(),
          success_rate: float(),
          failure_rate: float(),
          score: float()
        }

  @spec evaluate_recent(keyword()) :: metrics()
  def evaluate_recent(opts \\ []) do
    window_days = Keyword.get(opts, :window_days, 3)

    today = Date.utc_today()
    from = Date.add(today, -(max(window_days, 1) - 1))

    entries =
      Memory.get_range(Date.to_string(from), Date.to_string(today))

    metrics_from_entries(entries)
  end

  @spec evaluate_candidate(module(), keyword()) :: map()
  def evaluate_candidate(_module, opts \\ []) do
    baseline = Keyword.get(opts, :baseline, empty_metrics())
    candidate = Keyword.get(opts, :candidate, baseline)
    min_success_rate = Keyword.get(opts, :min_success_rate, 0.60)
    max_score_regression = Keyword.get(opts, :max_score_regression, 2.0)

    score_delta = candidate.score - baseline.score

    reasons =
      []
      |> maybe_add_reason(candidate.success_rate < min_success_rate, fn ->
        "candidate success_rate #{format_pct(candidate.success_rate)} below threshold #{format_pct(min_success_rate)}"
      end)
      |> maybe_add_reason(score_delta < -max_score_regression, fn ->
        "candidate score regressed by #{Float.round(-score_delta, 2)}"
      end)

    passed = reasons == []

    %{
      passed: passed,
      reasons: reasons,
      baseline: baseline,
      candidate: candidate,
      summary:
        "candidate_score=#{Float.round(candidate.score, 2)}, baseline_score=#{Float.round(baseline.score, 2)}, delta=#{Float.round(score_delta, 2)}, success=#{format_pct(candidate.success_rate)}"
    }
  end

  @spec metrics_from_entries([map()]) :: metrics()
  def metrics_from_entries(entries) do
    total = length(entries)

    success =
      Enum.count(entries, fn entry ->
        entry_result(entry) in ["SUCCESS", "DONE", "LEARNING", "STRATEGY"]
      end)

    failure =
      Enum.count(entries, fn entry ->
        entry_result(entry) in ["FAILURE", "ERROR"]
      end)

    success_rate = ratio(success, total)
    failure_rate = ratio(failure, total)

    # Weighted score: reward successful outcomes, penalize failures.
    score = success_rate * 100.0 - failure_rate * 35.0

    %{
      total: total,
      success: success,
      failure: failure,
      success_rate: success_rate,
      failure_rate: failure_rate,
      score: score
    }
  end

  defp empty_metrics do
    %{total: 0, success: 0, failure: 0, success_rate: 0.0, failure_rate: 0.0, score: 0.0}
  end

  defp entry_result(entry) do
    entry
    |> Map.get(:result, Map.get(entry, "result", ""))
    |> to_string()
    |> String.upcase()
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp maybe_add_reason(reasons, true, reason_fun), do: reasons ++ [reason_fun.()]
  defp maybe_add_reason(reasons, false, _reason_fun), do: reasons

  defp format_pct(value), do: "#{Float.round(value * 100.0, 1)}%"
end
