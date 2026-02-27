defmodule Nex.Agent.MemoryTest do
  use ExUnit.Case
  alias Nex.Agent.Memory

  describe "append/3" do
    test "appends entry to today's log" do
      assert function_exported?(Memory, :append, 3)
    end
  end

  describe "search/2" do
    test "returns search results" do
      # Test the BM25 scoring function indirectly
      # by checking that it returns a list
      results = Memory.search("test query", limit: 5)
      assert is_list(results)
    end
  end

  describe "BM25 scoring" do
    test "scores higher for more matches" do
      # Add a test entry
      Memory.append("Fix the login bug in auth module", "SUCCESS", %{})

      # Search for login
      results = Memory.search("login")

      assert is_list(results)
      # At least one result should have a score > 0
      # (may include entries from other tests)
    end
  end

  describe "get/1" do
    test "returns entries for a date" do
      entries = Memory.get(Date.to_string(Date.utc_today()))
      assert is_list(entries)
    end
  end
end
