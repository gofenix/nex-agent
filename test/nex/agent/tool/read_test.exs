defmodule Nex.Agent.Tool.ReadTest do
  use ExUnit.Case, async: true

  describe "Nex.Agent.Tool.Read.definition/0" do
    test "returns tool definition" do
      def = Nex.Agent.Tool.Read.definition()

      assert def.name == "read"
      assert is_binary(def.description)
      assert is_map(def.parameters)
    end

    test "definition has required fields" do
      def = Nex.Agent.Tool.Read.definition()

      assert def.parameters.properties.path != nil
      assert def.parameters.required == ["path"]
    end
  end

  describe "Nex.Agent.Tool.Read.execute/2" do
    test "reads existing file" do
      # Create a temp file
      tmp_file = "/tmp/nex_agent_test_read.txt"
      File.write!(tmp_file, "test content")

      try do
        result = Nex.Agent.Tool.Read.execute(%{"path" => tmp_file}, %{})

        assert {:ok, %{content: "test content"}} = result
      after
        File.rm!(tmp_file)
      end
    end

    test "handles missing file" do
      result = Nex.Agent.Tool.Read.execute(%{"path" => "/nonexistent/file.txt"}, %{})

      assert {:error, _} = result
    end

    test "truncates large files" do
      tmp_file = "/tmp/nex_agent_test_large.txt"
      large_content = String.duplicate("a", 60000)
      File.write!(tmp_file, large_content)

      try do
        result = Nex.Agent.Tool.Read.execute(%{"path" => tmp_file}, %{})

        assert {:ok, %{content: content}} = result
        assert content =~ "[Output truncated"
      after
        File.rm!(tmp_file)
      end
    end
  end
end
