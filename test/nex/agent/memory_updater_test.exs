defmodule Nex.Agent.MemoryUpdaterTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Memory, MemoryUpdater, Session, SessionManager, Skills}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-memory-updater-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Long-term Memory\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

    start_or_restart_supervised!({SessionManager, name: SessionManager})
    start_or_restart_supervised!({MemoryUpdater, name: MemoryUpdater})

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "serializes concurrent refreshes so later writes keep earlier durable facts", %{
    workspace: workspace
  } do
    parent = self()

    session_a =
      %{
        Session.new("session:a")
        | messages: build_messages("alpha"),
          metadata: %{
            "memory_refresh_llm_call_fun" =>
              fn messages, _opts ->
                send(parent, {:prompt_memory_a, prompt_memory_block(messages)})

                {:ok,
                 %{
                   "status" => "update",
                   "memory_update" =>
                     "# Long-term Memory\n\n## Workflow Lessons\n- Learned alpha.\n"
                 }}
              end
          }
      }

    session_b =
      %{
        Session.new("session:b")
        | messages: build_messages("beta"),
          metadata: %{
            "memory_refresh_llm_call_fun" =>
              fn messages, _opts ->
                prompt_memory = prompt_memory_block(messages)
                send(parent, {:prompt_memory_b, prompt_memory})
                assert prompt_memory =~ "Learned alpha."

                {:ok,
                 %{
                   "status" => "update",
                   "memory_update" =>
                     "# Long-term Memory\n\n## Workflow Lessons\n- Learned alpha.\n- Learned beta.\n"
                 }}
              end
          }
      }

    MemoryUpdater.enqueue(session_a, workspace: workspace)
    MemoryUpdater.enqueue(session_b, workspace: workspace)

    assert_receive {:prompt_memory_a, "(empty)"}, 1_000
    assert_receive {:prompt_memory_b, prompt_memory_b}, 1_000
    assert prompt_memory_b =~ "Learned alpha."

    wait_for(fn ->
      MemoryUpdater.status("session:a", workspace: workspace)["status"] == "idle" and
        MemoryUpdater.status("session:b", workspace: workspace)["status"] == "idle"
    end)

    memory = Memory.read_long_term(workspace: workspace)
    assert memory =~ "Learned alpha."
    assert memory =~ "Learned beta."
  end

  defp start_or_restart_supervised!(child_spec) do
    case start_supervised(child_spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp wait_for(predicate, attempts \\ 60)

  defp wait_for(_predicate, 0) do
    flunk("condition did not become true in time")
  end

  defp wait_for(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      wait_for(predicate, attempts - 1)
    end
  end

  defp build_messages(label) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    [
      %{"role" => "user", "content" => "teach #{label}", "timestamp" => now},
      %{"role" => "assistant", "content" => "done #{label}", "timestamp" => now}
    ]
  end

  defp prompt_memory_block(messages) do
    prompt = List.last(messages)["content"]

    [_, block] =
      Regex.run(~r/## Current Long-term Memory\n(.+?)\n\n## Conversation Segment/s, prompt)

    String.trim(block)
  end
end
