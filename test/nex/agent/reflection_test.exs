defmodule Nex.Agent.ReflectionTest do
  use ExUnit.Case
  alias Nex.Agent.Reflection

  describe "analyze/2" do
    test "analyzes successful and failed results" do
      results = [
        %{tool: "bash", args: %{"command" => "mix test"}, result: "SUCCESS"},
        %{tool: "read", args: %{"path" => "mix.exs"}, result: "SUCCESS"},
        %{
          tool: "bash",
          args: %{"command" => "mix compile"},
          result: "FAILURE",
          error: "compilation error"
        }
      ]

      analysis = Reflection.analyze(results)

      assert analysis.total == 3
      assert analysis.successes == 2
      assert analysis.failures == 1
      assert length(analysis.error_patterns) > 0
      assert is_list(analysis.insights)
    end

    test "handles empty results" do
      analysis = Reflection.analyze([])

      assert analysis.total == 0
      assert analysis.successes == 0
      assert analysis.failures == 0
    end
  end

  describe "suggest/1" do
    test "generates suggestions from analysis" do
      results = [
        %{tool: "bash", args: %{"command" => "mix test"}, result: "SUCCESS"},
        %{tool: "bash", args: %{"command" => "mix test"}, result: "SUCCESS"},
        %{
          tool: "bash",
          args: %{"command" => "mix test"},
          result: "FAILURE",
          error: "test failed"
        },
        %{tool: "bash", args: %{"command" => "mix test"}, result: "FAILURE", error: "test failed"}
      ]

      analysis = Reflection.analyze(results)
      suggestions = Reflection.suggest(analysis)

      assert is_list(suggestions)
      assert length(suggestions) > 0
    end
  end

  describe "reflect/2" do
    test "full reflection cycle" do
      results = [
        %{tool: "bash", args: %{"command" => "mix test"}, result: "SUCCESS"}
      ]

      reflection = Reflection.reflect(results, auto_apply: false)

      assert Map.has_key?(reflection, :analysis)
      assert Map.has_key?(reflection, :suggestions)
    end
  end
end
