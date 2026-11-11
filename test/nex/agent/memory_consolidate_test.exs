defmodule Nex.Agent.MemoryConsolidateTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Memory, MemoryUpdater, Session, SessionManager, Skills}
  alias Nex.Agent.Tool.MemoryConsolidate

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-memory-consolidate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Long-term Memory\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

    start_or_restart_supervised!({SessionManager, name: SessionManager})
    start_or_restart_supervised!({MemoryUpdater, name: MemoryUpdater})

    key = "memory-consolidate:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      SessionManager.invalidate(key, workspace: workspace)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, key: key}
  end

  test "memory_consolidate refreshes durable memory and persists reviewed progress", %{
    workspace: workspace,
    key: key
  } do
    :ok =
      Session.save(
        %{
          Session.new(key)
          | messages: build_messages(4),
            last_consolidated: 2
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
                      "status" => "update",
                      "memory_update" =>
                        "# Long-term Memory\n\n## Workflow Lessons\n- Confirmed durable lesson.\n"
                    }}
                 end
               }
             )

    assert result["status"] == "refreshed"
    assert result["reason"] == "ok"
    assert result["session_key"] == key
    assert result["last_reviewed_before"] == 2
    assert result["last_reviewed_after"] == 4
    assert result["memory_bytes"] > 0

    persisted = wait_for_session(key, workspace, &(&1.last_consolidated == 4))
    assert persisted.last_consolidated == 4
    assert Memory.read_long_term(workspace: workspace) =~ "Confirmed durable lesson"
  end

  test "memory_consolidate returns noop when there are no unreviewed messages", %{
    workspace: workspace,
    key: key
  } do
    total_messages = 4

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
                   flunk("llm_call_fun should not run when memory is already up to date")
                 end
               }
             )

    assert result["status"] == "noop"
    assert result["reason"] == "no_new_memory"
    assert result["last_reviewed_before"] == total_messages
    assert result["last_reviewed_after"] == total_messages
    refute_received :llm_called
  end

  test "memory_consolidate returns already_running when a background refresh is running", %{
    workspace: workspace,
    key: key
  } do
    persisted =
      %{
        Session.new(key)
        | messages: build_messages(4),
          last_consolidated: 0
      }

    :ok = Session.save(persisted, workspace: workspace)

    MemoryUpdater.enqueue(
      %{
        persisted
        | metadata: %{
            "memory_refresh_llm_call_fun" => fn _messages, _opts ->
              Process.sleep(200)
              {:ok, %{"status" => "noop"}}
            end
          }
      },
      workspace: workspace
    )

    wait_for(fn ->
      MemoryUpdater.status(key, workspace: workspace)["status"] == "running"
    end)

    assert {:ok, result} =
             MemoryConsolidate.execute(%{}, %{workspace: workspace, session_key: key})

    assert result["status"] == "already_running"
    assert result["reason"] == "memory_refresh_running"

    wait_for(fn ->
      MemoryUpdater.status(key, workspace: workspace)["status"] == "idle"
    end)
  end

  test "memory_consolidate surfaces refresh failures without changing reviewed progress", %{
    workspace: workspace,
    key: key
  } do
    :ok =
      Session.save(
        %{
          Session.new(key)
          | messages: build_messages(4),
            last_consolidated: 1
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

    assert Session.load(key, workspace: workspace).last_consolidated == 1
    assert Memory.read_long_term(workspace: workspace) == "# Long-term Memory\n"
  end

  defp start_or_restart_supervised!(child_spec) do
    case start_supervised(child_spec) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid
    end
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

  defp wait_for(predicate, attempts \\ 40)

  defp wait_for(_predicate, 0) do
    flunk("condition did not become true in time")
  end

  defp wait_for(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      wait_for(predicate, attempts - 1)
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
