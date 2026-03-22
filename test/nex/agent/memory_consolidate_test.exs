defmodule Nex.Agent.MemoryConsolidateTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Memory, Session, SessionManager, Skills}
  alias Nex.Agent.Tool.MemoryConsolidate

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-memory-consolidate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Long-term Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "# Conversation History Log\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

    if Process.whereis(SessionManager) == nil do
      start_supervised!({SessionManager, name: SessionManager})
    end

    key = "memory-consolidate:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      SessionManager.invalidate(key, workspace: workspace)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, key: key}
  end

  test "memory_consolidate runs normal consolidation and persists progress", %{
    workspace: workspace,
    key: key
  } do
    :ok =
      Session.save(
        %{
          Session.new(key)
          | messages: build_messages(63),
            last_consolidated: 10
        },
        workspace: workspace
      )

    assert {:ok, result} =
             MemoryConsolidate.execute(
               %{},
               %{
                 workspace: workspace,
                 session_key: key,
                 provider: :anthropic,
                 model: "claude-sonnet-4-20250514",
                 llm_call_fun: fn _messages, _opts ->
                   {:ok,
                    %{
                      "history_entry" => "[2026-03-22 16:00] Triggered explicit consolidation.",
                      "memory_update" =>
                        "# Long-term Memory\n\n## Consolidated Facts\nImmediate consolidation succeeded.\n"
                    }}
                 end
               }
             )

    assert result["status"] == "consolidated"
    assert result["reason"] == "ok"
    assert result["session_key"] == key
    assert result["last_consolidated_before"] == 10
    assert result["last_consolidated_after"] == 38
    assert result["memory_bytes"] > 0
    assert result["history_bytes"] > 0

    persisted =
      wait_for_session(key, workspace, fn session ->
        session.last_consolidated == 38 and
          get_in(session.metadata, ["consolidation_in_progress"]) != true
      end)

    assert persisted.last_consolidated == 38
    assert Memory.read_long_term(workspace: workspace) =~ "Immediate consolidation succeeded"

    assert File.read!(Path.join(workspace, "memory/HISTORY.md")) =~
             "Triggered explicit consolidation"
  end

  test "memory_consolidate returns noop when there are no unconsolidated messages", %{
    workspace: workspace,
    key: key
  } do
    total_messages = 40

    :ok =
      Session.save(
        %{
          Session.new(key)
          | messages: build_messages(total_messages),
            last_consolidated: total_messages
        },
        workspace: workspace
      )

    parent = self()

    assert {:ok, result} =
             MemoryConsolidate.execute(
               %{},
               %{
                 workspace: workspace,
                 session_key: key,
                 llm_call_fun: fn _messages, _opts ->
                   send(parent, :llm_called)
                   flunk("llm_call_fun should not run when consolidation is a noop")
                 end
               }
             )

    assert result["status"] == "noop"
    assert result["reason"] == "no_unconsolidated_messages"
    assert result["last_consolidated_before"] == total_messages
    assert result["last_consolidated_after"] == total_messages
    refute_received :llm_called

    persisted =
      wait_for_session(key, workspace, fn session ->
        get_in(session.metadata, ["consolidation_in_progress"]) != true
      end)

    assert persisted.last_consolidated == total_messages
  end

  test "memory_consolidate returns noop when the session is still below the keep window", %{
    workspace: workspace,
    key: key
  } do
    :ok =
      Session.save(
        %{
          Session.new(key)
          | messages: build_messages(12),
            last_consolidated: 0
        },
        workspace: workspace
      )

    parent = self()

    assert {:ok, result} =
             MemoryConsolidate.execute(
               %{},
               %{
                 workspace: workspace,
                 session_key: key,
                 llm_call_fun: fn _messages, _opts ->
                   send(parent, :llm_called)
                   flunk("llm_call_fun should not run below the keep window")
                 end
               }
             )

    assert result["status"] == "noop"
    assert result["reason"] == "below_keep_window"
    assert result["last_consolidated_before"] == 0
    assert result["last_consolidated_after"] == 0
    refute_received :llm_called
  end

  test "memory_consolidate returns already_running when consolidation is already in progress", %{
    workspace: workspace,
    key: key
  } do
    :ok =
      Session.save(
        %{
          Session.new(key)
          | messages: build_messages(63),
            last_consolidated: 10,
            metadata: %{
              "consolidation_in_progress" => true,
              "consolidation_started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
        },
        workspace: workspace
      )

    assert {:ok, result} =
             MemoryConsolidate.execute(%{}, %{workspace: workspace, session_key: key})

    assert result["status"] == "already_running"
    assert result["reason"] == "consolidation_in_progress"
    assert result["last_consolidated_before"] == 10
    assert result["last_consolidated_after"] == 10
  end

  test "memory_consolidate clears the in-progress flag when consolidation fails", %{
    workspace: workspace,
    key: key
  } do
    :ok =
      Session.save(
        %{
          Session.new(key)
          | messages: build_messages(63),
            last_consolidated: 10
        },
        workspace: workspace
      )

    assert {:error, "moonshot empty body"} =
             MemoryConsolidate.execute(
               %{},
               %{
                 workspace: workspace,
                 session_key: key,
                 provider: :anthropic,
                 model: "claude-sonnet-4-20250514",
                 llm_call_fun: fn _messages, _opts -> {:error, "moonshot empty body"} end
               }
             )

    persisted =
      wait_for_session(key, workspace, fn session ->
        get_in(session.metadata, ["consolidation_in_progress"]) != true
      end)

    assert persisted.last_consolidated == 10
    assert Memory.read_long_term(workspace: workspace) == "# Long-term Memory\n"
    assert File.read!(Path.join(workspace, "memory/HISTORY.md")) == "# Conversation History Log\n"
  end

  defp wait_for_session(key, workspace, predicate, attempts \\ 40)

  defp wait_for_session(_key, _workspace, _predicate, 0) do
    flunk("session did not reach the expected state in time")
  end

  defp wait_for_session(key, workspace, predicate, attempts) do
    session = Session.load(key, workspace: workspace)

    if predicate.(session) do
      session
    else
      Process.sleep(10)
      wait_for_session(key, workspace, predicate, attempts - 1)
    end
  end

  defp build_messages(count) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.map(1..count, fn i ->
      %{
        "role" => if(rem(i, 2) == 0, do: "assistant", else: "user"),
        "content" => "message-#{i}",
        "timestamp" => now
      }
    end)
  end
end
