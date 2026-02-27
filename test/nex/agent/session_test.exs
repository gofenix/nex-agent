defmodule Nex.Agent.SessionTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Session
  alias Nex.Agent.Entry

  describe "Session.create/2" do
    test "creates a new session with valid project_id" do
      project_id = "test_project_#{:rand.uniform(10000)}"
      {:ok, session} = Session.create(project_id)

      assert session.id != nil
      assert session.project_id == project_id
      assert is_list(session.entries)
      assert session.current_entry_id != nil
    end

    test "creates session with custom cwd" do
      project_id = "test_project_#{:rand.uniform(10000)}"
      cwd = File.cwd!()
      {:ok, session} = Session.create(project_id, cwd)

      assert session.project_id == project_id
    end
  end

  describe "Session.add_entry/2" do
    test "adds an entry to the session" do
      {:ok, session} = Session.create("test_project_#{:rand.uniform(10000)}")
      parent_id = hd(session.entries).id
      entry = Entry.new_message(parent_id, %{role: "user", content: "Hello"})

      updated_session = Session.add_entry(session, entry)

      assert length(updated_session.entries) == 2
      assert updated_session.current_entry_id == entry.id
    end
  end

  describe "Session.fork/1" do
    test "forks a session" do
      {:ok, session} = Session.create("test_project_#{:rand.uniform(10000)}")
      parent_id = hd(session.entries).id
      entry = Entry.new_message(parent_id, %{role: "user", content: "Hello"})
      session = Session.add_entry(session, entry)

      {:ok, forked} = Session.fork(session)

      assert forked.id != session.id
      assert forked.project_id == session.project_id <> "-fork"
      assert length(forked.entries) >= length(session.entries)
    end
  end

  describe "Session.navigate/2" do
    test "navigates to a specific entry" do
      {:ok, session} = Session.create("test_project_#{:rand.uniform(10000)}")
      entry1 = Entry.new_message(hd(session.entries).id, %{role: "user", content: "First"})
      entry2 = Entry.new_message(entry1.id, %{role: "user", content: "Second"})

      session =
        session
        |> Session.add_entry(entry1)
        |> Session.add_entry(entry2)

      {:ok, navigated} = Session.navigate(session, entry1.id)

      assert navigated.current_entry_id == entry1.id
    end

    test "returns error for non-existent entry" do
      {:ok, session} = Session.create("test_project_#{:rand.uniform(10000)}")
      result = Session.navigate(session, "non_existent_id")

      assert result == {:error, :entry_not_found}
    end
  end

  describe "Session.current_path/1" do
    test "returns current path of entries" do
      {:ok, session} = Session.create("test_project_#{:rand.uniform(10000)}")
      path = Session.current_path(session)

      assert is_list(path)
    end
  end

  describe "Session.branches/1" do
    test "returns branches from session" do
      {:ok, session} = Session.create("test_project_#{:rand.uniform(10000)}")
      branches = Session.branches(session)

      assert is_list(branches)
    end
  end

  describe "Session.current_messages/1" do
    test "returns messages from current path" do
      {:ok, session} = Session.create("test_project_#{:rand.uniform(10000)}")
      messages = Session.current_messages(session)

      assert is_list(messages)
    end
  end

  describe "Session.get_latest_model/1" do
    test "returns nil when no model change" do
      {:ok, session} = Session.create("test_project_#{:rand.uniform(10000)}")
      result = Session.get_latest_model(session)

      assert result == nil
    end

    test "returns model from model_change entry" do
      {:ok, session} = Session.create("test_project_#{:rand.uniform(10000)}")
      model_entry = Entry.new_model_change(session.current_entry_id, :anthropic, "claude-3")
      session = Session.add_entry(session, model_entry)

      result = Session.get_latest_model(session)

      assert result == {:anthropic, "claude-3"}
    end
  end

  describe "Session.load/2" do
    test "loads a saved session" do
      project_id = "test_load_#{:rand.uniform(10000)}"
      {:ok, session} = Session.create(project_id)
      session_id = session.id

      entry1 = Entry.new_message(session.current_entry_id, %{role: "user", content: "Hello"})
      session = Session.add_entry(session, entry1)

      {:ok, loaded} = Session.load(session_id, project_id)

      assert loaded.id == session_id
      assert loaded.project_id == project_id
    end

    test "returns error for non-existent session" do
      result = Session.load("non_existent_12345", "non_existent_project")
      assert match?({:error, _}, result)
    end
  end
end
