defmodule NexAgentConsole.MixProject do
  use Mix.Project

  def project do
    [
      app: :nex_agent_console,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {NexAgentConsole.Application, []}
    ]
  end

  defp deps do
    [
      nex_dep(),
      {:nex_agent, path: ".."},
      {:dotenvy, "~> 1.1", override: true}
    ]
  end

  defp nex_dep do
    local_path = Path.expand("../../nex/framework", __DIR__)

    if File.dir?(local_path) do
      {:nex_core, path: local_path}
    else
      {:nex_core, "~> 0.4.2"}
    end
  end

  defp elixirc_paths(:test), do: ["src", "test/support"]
  defp elixirc_paths(_env), do: ["src"]
end
