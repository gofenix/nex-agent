defmodule Nex.Agent.Tool.WriteTest do
  use ExUnit.Case, async: true

  describe "Nex.Agent.Tool.Write.definition/0" do
    test "returns tool definition" do
      def = Nex.Agent.Tool.Write.definition()

      assert def.name == "write"
      assert is_binary(def.description)
      assert is_map(def.parameters)
    end

    test "definition has required fields" do
      def = Nex.Agent.Tool.Write.definition()

      assert def.parameters.properties.path != nil
      assert def.parameters.properties.content != nil
      assert def.parameters.required == ["path", "content"]
    end
  end

  describe "Nex.Agent.Tool.Write.execute/2" do
    test "writes to file" do
      tmp_file = "/tmp/nex_agent_test_write.txt"

      result =
        Nex.Agent.Tool.Write.execute(
          %{
            "path" => tmp_file,
            "content" => "hello world"
          },
          %{}
        )

      try do
        assert {:ok, %{success: true, path: _}} = result
        assert File.read!(tmp_file) == "hello world"
      after
        File.rm!(tmp_file)
      end
    end

    test "overwrites existing file" do
      tmp_file = "/tmp/nex_agent_test_overwrite.txt"
      File.write!(tmp_file, "original")

      try do
        result =
          Nex.Agent.Tool.Write.execute(
            %{
              "path" => tmp_file,
              "content" => "new content"
            },
            %{}
          )

        assert {:ok, %{success: true}} = result
        assert File.read!(tmp_file) == "new content"
      after
        File.rm!(tmp_file)
      end
    end

    test "handles invalid path" do
      result =
        Nex.Agent.Tool.Write.execute(
          %{
            "path" => "/nonexistent/path/file.txt",
            "content" => "test"
          },
          %{}
        )

      assert {:error, _} = result
    end
  end
end
