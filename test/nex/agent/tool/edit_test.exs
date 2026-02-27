defmodule Nex.Agent.Tool.EditTest do
  use ExUnit.Case, async: true

  describe "definition/0" do
    test "returns tool definition" do
      def_result = Nex.Agent.Tool.Edit.definition()
      assert def_result.name == "edit"
      assert is_binary(def_result.description)
    end
  end

  describe "execute/2" do
    test "edits existing file" do
      tmp = "/tmp/nex_test_edit_#{:rand.uniform(10000)}.txt"
      File.write!(tmp, "hello world")

      try do
        result = Nex.Agent.Tool.Edit.execute(
          %{"path" => tmp, "search" => "world", "replace" => "elixir"},
          %{}
        )

        assert {:ok, %{success: true}} = result
        File.rm(tmp)
      after
        File.rm(tmp)
      end
    end

    test "returns error when file does not exist" do
      result = Nex.Agent.Tool.Edit.execute(
        %{
          "path" => "/nonexistent/path/file.txt",
          "search" => "text",
          "replace" => "replacement"
        },
        %{}
      )

      assert {:error, message} = result
      assert message =~ "Failed to read file"
    end

    test "returns error when search text not found" do
      tmp = "/tmp/nex_test_edit_notfound_#{:rand.uniform(10000)}.txt"
      File.write!(tmp, "hello world")

      try do
        result = Nex.Agent.Tool.Edit.execute(
          %{
            "path" => tmp,
            "search" => "text that doesn't exist",
            "replace" => "replacement"
          },
          %{}
        )

        assert {:error, message} = result
        assert message =~ "Text not found in file"
      after
        File.rm(tmp)
      end
    end

    test "only replaces first occurrence" do
      tmp = "/tmp/nex_test_edit_multi_#{:rand.uniform(10000)}.txt"
      File.write!(tmp, "hello hello hello")

      try do
        result = Nex.Agent.Tool.Edit.execute(
          %{
            "path" => tmp,
            "search" => "hello",
            "replace" => "hi"
          },
          %{}
        )

        assert {:ok, %{success: true}} = result
        assert File.read!(tmp) == "hi hello hello"
      after
        File.rm(tmp)
      end
    end

    test "handles empty replacement" do
      tmp = "/tmp/nex_test_edit_empty_#{:rand.uniform(10000)}.txt"
      File.write!(tmp, "hello world")

      try do
        result = Nex.Agent.Tool.Edit.execute(
          %{
            "path" => tmp,
            "search" => "world",
            "replace" => ""
          },
          %{}
        )

        assert {:ok, %{success: true}} = result
        assert File.read!(tmp) == "hello "
      after
        File.rm(tmp)
      end
    end
  end
end
