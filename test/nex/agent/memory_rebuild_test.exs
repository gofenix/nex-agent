defmodule Nex.Agent.MemoryRebuildTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Memory, Session, SessionManager, Skills}
  alias Nex.Agent.Tool.MemoryRebuild

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-memory-rebuild-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Long-term Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "# Conversation History Log\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

    if Process.whereis(SessionManager) == nil do
      start_supervised!({SessionManager, name: SessionManager})
    end

    key = "memory-rebuild:#{System.unique_integer([:positive])}"

    session =
      Session.new(key)
      |> Map.put(:messages, build_messages())
      |> Map.put(:last_consolidated, 1)

    :ok = Session.save(session)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      SessionManager.invalidate(key)
      File.rm_rf!(workspace)
      File.rm_rf!(session_dir_for(key))
    end)

    {:ok, workspace: workspace, key: key}
  end

  test "memory_rebuild performs archive_all consolidation and persists progress", %{
    workspace: workspace,
    key: key
  } do
    parent = self()

    llm_call_fun = fn _messages, _opts ->
      send(parent, :batch_called)

      {:ok,
       %{
         "history_entry" =>
           "[2026-03-15 11:00] Rebuilt memory for the whole session and captured the main decisions.",
         "memory_update" =>
           "# Long-term Memory\n\nProject uses full-session rebuilds when needed.\n"
       }}
    end

    assert {:ok, result} =
             MemoryRebuild.execute(
               %{},
               %{
                 workspace: workspace,
                 session_key: key,
                 provider: :anthropic,
                 model: "claude-sonnet-4-20250514",
                 llm_call_fun: llm_call_fun,
                 batch_messages: 2
               }
             )

    assert_receive :batch_called
    assert_receive :batch_called

    assert result["session_key"] == key
    assert result["processed_messages"] == 4
    assert result["batches_processed"] == 2
    assert result["batch_messages"] == 2
    assert result["last_consolidated_before"] == 1
    assert result["last_consolidated_after"] == 4

    reloaded = Session.load(key)
    assert reloaded.last_consolidated == 4
    assert Memory.read_long_term(workspace: workspace) =~ "full-session rebuilds"

    assert File.read!(Path.join(workspace, "memory/HISTORY.md")) =~
             "Rebuilt memory for the whole session"
  end

  defp build_messages do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    [
      %{"role" => "user", "content" => "first", "timestamp" => now},
      %{"role" => "assistant", "content" => "second", "timestamp" => now},
      %{"role" => "user", "content" => "third", "timestamp" => now},
      %{"role" => "assistant", "content" => "fourth", "timestamp" => now}
    ]
  end

  defp session_dir_for(key) do
    safe_filename =
      key
      |> String.replace(":", "_")
      |> String.replace(~r/[^\w-]/, "_")

    Path.join([
      System.get_env("HOME", "~"),
      ".nex/agent/workspace/sessions",
      safe_filename
    ])
  end
end
