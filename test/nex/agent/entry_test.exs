defmodule Nex.Agent.EntryTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Entry

  describe "Entry.new/2" do
    test "creates entry with default values" do
      entry = Entry.new(:message)
      assert entry.type == :message
      assert entry.id != nil
      assert entry.timestamp != nil
      assert entry.version == 3
      assert entry.data == %{}
    end

    test "creates entry with custom id" do
      entry = Entry.new(:message, %{id: "custom-id-123"})
      assert entry.id == "custom-id-123"
    end

    test "creates entry with custom parent_id" do
      entry = Entry.new(:message, %{parent_id: "parent-456"})
      assert entry.parent_id == "parent-456"
    end

    test "creates entry with custom version" do
      entry = Entry.new(:message, %{version: 5})
      assert entry.version == 5
    end

    test "generates unique ids by default" do
      entry1 = Entry.new(:message)
      entry2 = Entry.new(:message)
      assert entry1.id != entry2.id
    end
  end

  describe "Entry.new_session/1" do
    test "creates session entry" do
      entry = Entry.new_session("my-project")
      assert entry.type == :session
      assert entry.data.project_id == "my-project"
      assert entry.id != nil
      assert entry.parent_id == nil
    end
  end

  describe "Entry.new_message/3" do
    test "creates message entry without tool_call_id" do
      entry = Entry.new_message("parent-123", %{role: "user", content: "Hello"})
      assert entry.type == :message
      assert entry.parent_id == "parent-123"
      assert entry.message.role == "user"
      refute Map.has_key?(entry.message, :toolCallId)
    end

    test "creates message entry with tool_call_id" do
      entry = Entry.new_message("parent-123", %{role: "assistant", content: "Result"}, "tool-call-456")
      assert entry.message.toolCallId == "tool-call-456"
    end
  end

  describe "Entry.new_model_change/3" do
    test "creates model change entry" do
      entry = Entry.new_model_change("parent-123", :openai, "gpt-4")
      assert entry.type == :model_change
      assert entry.parent_id == "parent-123"
      assert entry.data.provider == :openai
      assert entry.data.model == "gpt-4"
    end
  end

  describe "Entry.new_compaction/3" do
    test "creates compaction entry" do
      entry = Entry.new_compaction("parent-123", "Summary", 1000)
      assert entry.type == :compaction
      assert entry.parent_id == "parent-123"
      assert entry.summary == "Summary"
      assert entry.data.tokens_before == 1000
    end
  end

  describe "Entry.new_label/3" do
    test "creates label entry" do
      entry = Entry.new_label("parent-123", "target-456", "Checkpoint")
      assert entry.type == :label
      assert entry.parent_id == "parent-123"
      assert entry.data.target_id == "target-456"
      assert entry.data.label == "Checkpoint"
    end
  end

  describe "Entry.to_json/1" do
    test "converts entry to JSON" do
      entry = Entry.new(:message, %{parent_id: "parent-123", message: %{role: "user", content: "Hello"}})
      json = Entry.to_json(entry)
      assert is_binary(json)
      assert json =~ "message"
      assert json =~ "parent_id"
      refute json =~ "__struct__"
    end
  end

  describe "Entry.from_json/1" do
    test "parses JSON back to entry" do
      original = Entry.new(:message, %{parent_id: "parent-123", message: %{role: "user", content: "Hello"}})
      json = Entry.to_json(original)
      {:ok, parsed} = Entry.from_json(json)
      assert parsed.type == original.type
      assert parsed.id == original.id
      assert parsed.parent_id == original.parent_id
    end

    test "parses session entry JSON" do
      original = Entry.new_session("my-project")
      json = Entry.to_json(original)
      {:ok, parsed} = Entry.from_json(json)
      assert parsed.type == :session
      assert parsed.data["project_id"] == "my-project"
    end

    test "parses model change entry JSON" do
      original = Entry.new_model_change("parent-123", :openai, "gpt-4")
      json = Entry.to_json(original)
      {:ok, parsed} = Entry.from_json(json)
      assert parsed.type == :model_change
      assert parsed.data["provider"] == "openai"
    end

    test "returns error for invalid JSON" do
      result = Entry.from_json("not valid json")
      assert match?({:error, _}, result)
    end
  end

  describe "Entry timestamp generation" do
    test "generates ISO8601 timestamp" do
      entry = Entry.new(:message)
      assert is_binary(entry.timestamp)
      assert String.contains?(entry.timestamp, "T")
    end
  end

  describe "Entry struct defaults" do
    test "default data is empty map" do
      entry = Entry.new(:message)
      assert entry.data == %{}
    end

    test "default version is 3" do
      entry = Entry.new(:message)
      assert entry.version == 3
    end
  end
end
