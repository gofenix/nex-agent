defmodule Nex.Agent.KnowledgeTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Knowledge, Skills}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-knowledge-#{System.unique_integer([:positive])}")

    previous_workspace = Application.get_env(:nex_agent, :workspace_path)
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Nex.Agent.Onboarding.ensure_initialized()
    Skills.load()

    note_path = Path.join([workspace, "notes", "release-note.md"])
    File.mkdir_p!(Path.dirname(note_path))
    File.write!(note_path, "Release process: run tests, tag, publish.\n")

    on_exit(fn ->
      if previous_workspace do
        Application.put_env(:nex_agent, :workspace_path, previous_workspace)
      else
        Application.delete_env(:nex_agent, :workspace_path)
      end

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, note_path: note_path}
  end

  test "capture chat, note, and web knowledge and promote into durable layers", %{
    workspace: workspace
  } do
    assert {:ok, chat_capture} =
             Knowledge.capture(
               %{
                 "source" => "chat_message",
                 "title" => "User preference",
                 "content" => "The user prefers concise Chinese replies."
               },
               workspace: workspace
             )

    assert {:ok, note_capture} =
             Knowledge.capture(
               %{"source" => "workspace_note", "path" => "notes/release-note.md"},
               workspace: workspace
             )

    assert {:ok, web_capture} =
             Knowledge.capture(
               %{
                 "source" => "web_page",
                 "url" => "https://example.com/guide",
                 "title" => "Guide"
               },
               workspace: workspace,
               fetch_fun: fn _url -> {:ok, "Deploy guide with rollback checklist."} end
             )

    captures = Knowledge.list(workspace: workspace, limit: 10)
    assert length(captures) == 3
    assert Enum.any?(captures, &(&1["id"] == chat_capture["id"]))
    assert Enum.any?(captures, &(&1["id"] == note_capture["id"]))
    assert Enum.any?(captures, &(&1["id"] == web_capture["id"]))

    assert {:ok, %{"target" => "memory"}} =
             Knowledge.promote(note_capture["id"], "memory", workspace: workspace)

    assert {:ok, %{"target" => "user"}} =
             Knowledge.promote(chat_capture["id"], "user", workspace: workspace)

    assert {:ok, %{"target" => "project", "project" => "nex-agent"}} =
             Knowledge.promote(
               web_capture["id"],
               "project",
               workspace: workspace,
               project: "nex-agent"
             )

    assert {:ok, %{"target" => "skill"}} =
             Knowledge.promote(note_capture["id"], "skill", workspace: workspace)

    assert File.read!(Path.join(workspace, "memory/MEMORY.md")) =~ "Release process"
    assert File.read!(Path.join(workspace, "USER.md")) =~ "prefers concise Chinese replies"
    assert File.read!(Path.join(workspace, "projects/nex-agent/PROJECT.md")) =~ "Deploy guide"
    assert File.exists?(Path.join(workspace, "skills/release_note_md/SKILL.md"))
  end

  test "workspace_note capture rejects sibling paths outside the workspace", %{
    workspace: workspace
  } do
    escaped_dir = workspace <> "-evil"
    escaped_note = Path.join(escaped_dir, "note.md")
    File.mkdir_p!(escaped_dir)
    File.write!(escaped_note, "This should never be readable.\n")

    on_exit(fn -> File.rm_rf!(escaped_dir) end)

    assert {:error, "workspace_note path must stay inside the workspace"} =
             Knowledge.capture(
               %{
                 "source" => "workspace_note",
                 "path" => "../#{Path.basename(escaped_dir)}/note.md"
               },
               workspace: workspace
             )
  end

  test "get can still find captures older than the recent listing window", %{workspace: workspace} do
    captures =
      for idx <- 1..205 do
        {:ok, capture} =
          Knowledge.capture(
            %{
              "source" => "chat_message",
              "title" => "Capture #{idx}",
              "content" => "content #{idx}"
            },
            workspace: workspace
          )

        capture
      end

    oldest = hd(captures)

    assert oldest["title"] == "Capture 1"
    assert Knowledge.get(oldest["id"], workspace: workspace)["title"] == "Capture 1"
  end
end
