defmodule Mix.Tasks.Nex.Agent.ReviewSubagent do
  @moduledoc """
  Review SubAgent performance and generate code upgrade suggestions.

  ## Usage

      # Check if a SubAgent needs review
      mix nex.agent.review_subagent check MyApp.SubAgent.CodeExpert

      # Show review report
      mix nex.agent.review_subagent report MyApp.SubAgent.CodeExpert

      # Apply code upgrade manually after review
      mix nex.agent.review_subagent apply MyApp.SubAgent.CodeExpert --version v1.0.1

  ## Options

    * `--window` - Time window for analysis (1d, 7d, 30d), default: 7d
    * `--min-tasks` - Minimum tasks before suggesting a review, default: 10
  """

  use Mix.Task

  alias Nex.Agent.SubAgent.Review

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["check", module_str | opts] ->
        module = String.to_atom("Elixir.#{module_str}")
        window = get_option(opts, "--window", "7d")
        min_tasks = get_option(opts, "--min-tasks", "10") |> String.to_integer()

        check_review(module, window: window, min_tasks: min_tasks)

      ["report", module_str | opts] ->
        module = String.to_atom("Elixir.#{module_str}")
        window = get_option(opts, "--window", "7d")
        min_tasks = get_option(opts, "--min-tasks", "10") |> String.to_integer()

        generate_report(module, window: window, min_tasks: min_tasks)

      ["apply", module_str | opts] ->
        module = String.to_atom("Elixir.#{module_str}")
        version = get_option(opts, "--version", nil)

        if version do
          apply_upgrade(module, version)
        else
          Mix.shell().error("Error: --version is required for apply")
          exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().info(@moduledoc)
    end
  end

  defp check_review(module, opts) do
    Mix.shell().info("🔍 Analyzing #{module} performance...")

    case Review.self_reflect(module, opts) do
      {:ok, nil} ->
        Mix.shell().info("✅ No code upgrade review needed. Performance is good.")

      {:ok, suggestion} ->
        Mix.shell().info("\n🤖 Review Suggestion Found!")
        Mix.shell().info("Risk Level: #{String.upcase(to_string(suggestion.risk_level))}")
        Mix.shell().info("Reason: #{suggestion.reason}")
        Mix.shell().info("\nSuggested Changes:")

        Enum.each(suggestion.changes, fn change ->
          Mix.shell().info("  - #{change}")
        end)

        Mix.shell().info(
          "\nRun `mix nex.agent.review_subagent report #{module}` for full details"
        )
    end
  end

  defp generate_report(module, opts) do
    Mix.shell().info("📊 Generating review report for #{module}...")

    case Review.self_reflect(module, opts) do
      {:ok, nil} ->
        Mix.shell().info("No review suggestion available.")

      {:ok, suggestion} ->
        report = Review.generate_report(suggestion)
        Mix.shell().info("\n" <> report)
    end
  end

  defp apply_upgrade(_module, _version) do
    Mix.shell().info("⚠️  Automatic code upgrade application not yet implemented.")
    Mix.shell().info("Please review the report and manually use `upgrade_code` tool.")

    # Future: Integrate with UpgradeManager
    # Nex.Agent.UpgradeManager.upgrade(module, new_code, reason: "Subagent review: #{version}")
  end

  defp get_option(opts, flag, default) do
    case Enum.find_index(opts, &(&1 == flag)) do
      nil -> default
      idx -> Enum.at(opts, idx + 1, default)
    end
  end
end
