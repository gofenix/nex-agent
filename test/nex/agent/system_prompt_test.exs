defmodule Nex.Agent.SystemPromptTest do
  use ExUnit.Case, async: true

  describe "Nex.Agent.SystemPrompt.build/1" do
    test "returns a string" do
      result = Nex.Agent.SystemPrompt.build()
      assert is_binary(result)
    end

    test "contains date header" do
      result = Nex.Agent.SystemPrompt.build()
      assert result =~ "Date:"
    end

    test "contains tools section" do
      result = Nex.Agent.SystemPrompt.build()
      assert result =~ "## Tools"
    end

    test "contains guidelines section" do
      result = Nex.Agent.SystemPrompt.build()
      assert result =~ "## Guidelines"
    end

    test "contains tool descriptions" do
      result = Nex.Agent.SystemPrompt.build()
      assert result =~ "read:"
      assert result =~ "bash:"
      assert result =~ "edit:"
      assert result =~ "write:"
    end

    test "accepts cwd option" do
      result = Nex.Agent.SystemPrompt.build(cwd: "/tmp")
      assert is_binary(result)
    end

    test "includes AGENTS.md content when present" do
      tmp_dir = "/tmp/nex_test_#{:rand.uniform(10000)}"
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "Test instructions for agent")

      try do
        result = Nex.Agent.SystemPrompt.build(cwd: tmp_dir)
        assert result =~ "## Project Instructions"
        assert result =~ "Test instructions for agent"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "includes SYSTEM.md content when present" do
      tmp_dir = "/tmp/nex_test_#{:rand.uniform(10000)}"
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "SYSTEM.md"), "System-level instructions")

      try do
        result = Nex.Agent.SystemPrompt.build(cwd: tmp_dir)
        assert result =~ "## System Instructions"
        assert result =~ "System-level instructions"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "includes both AGENTS.md and SYSTEM.md when both present" do
      tmp_dir = "/tmp/nex_test_#{:rand.uniform(10000)}"
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "Project instructions")
      File.write!(Path.join(tmp_dir, "SYSTEM.md"), "System instructions")

      try do
        result = Nex.Agent.SystemPrompt.build(cwd: tmp_dir)
        assert result =~ "## Project Instructions"
        assert result =~ "## System Instructions"
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end
end
