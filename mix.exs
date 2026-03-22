defmodule NexAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :nex_agent,
      version: "0.2.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [summary: [threshold: 0]],
      dialyzer: [
        plt_add_apps: [:mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto],
      mod: {Nex.Agent.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:req_llm, git: "https://github.com/gofenix/req_llm.git", branch: "nex-agent-moonshot-fix"},
      {:jason, "~> 1.4"},
      {:websockex, "~> 0.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp elixirc_paths(_env), do: ["lib/nex", "lib/mix"]
end
