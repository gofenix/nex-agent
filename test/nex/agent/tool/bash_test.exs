defmodule Nex.Agent.Tool.BashTest do
  use ExUnit.Case, async: true

  describe "Nex.Agent.Tool.Bash.definition/0" do
    test "returns tool definition" do
      def_result = Nex.Agent.Tool.Bash.definition()

      assert def_result.name == "bash"
      assert is_binary(def_result.description)
      assert is_map(def_result.parameters)
    end

    test "definition has required fields" do
      def_result = Nex.Agent.Tool.Bash.definition()

      assert def_result.parameters.properties.command != nil
      assert def_result.parameters.required == ["command"]
    end
  end

  describe "Nex.Agent.Tool.Bash.execute/2" do
    test "executes simple command" do
      result = Nex.Agent.Tool.Bash.execute(%{"command" => "echo hello"}, %{})

      assert {:ok, %{content: content, exit_code: 0}} = result
      assert content =~ "hello"
    end

    test "executes command in custom cwd" do
      result = Nex.Agent.Tool.Bash.execute(%{"command" => "pwd"}, %{cwd: "/tmp"})

      assert {:ok, %{content: content}} = result
      assert content =~ "/tmp"
    end

    test "handles command with exit code" do
      result = Nex.Agent.Tool.Bash.execute(%{"command" => "exit 1"}, %{})

      assert {:ok, %{content: _, exit_code: 1}} = result
    end

    test "handles failing command" do
      result =
        Nex.Agent.Tool.Bash.execute(
          %{"command" => "invalid_command_xyz_that_does_not_exist"},
          %{}
        )

      assert {:ok, %{exit_code: _}} = result
    end

    test "handles very long output truncation" do
      result = Nex.Agent.Tool.Bash.execute(%{"command" => "seq 1 10000"}, %{})

      assert {:ok, %{content: content, exit_code: 0}} = result
      assert String.length(content) <= 50020
      assert content =~ ~r/\d+/
    end

    test "handles mixed success and error output" do
      result = Nex.Agent.Tool.Bash.execute(%{"command" => "echo stdout; echo stderr >&2"}, %{})

      assert {:ok, %{content: content, exit_code: 0}} = result
      assert content =~ "stdout"
      assert content =~ "stderr"
    end

    test "handles empty command" do
      result = Nex.Agent.Tool.Bash.execute(%{"command" => ""}, %{})
      assert {:ok, %{exit_code: 0}} = result
    end

    test "handles timeout option" do
      result = Nex.Agent.Tool.Bash.execute(%{"command" => "sleep 1"}, %{timeout: 2})
      assert {:ok, %{exit_code: 0}} = result
    end
  end
end
