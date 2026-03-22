defmodule Nex.Agent.MemoryConsolidationTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Memory, Runner, Session}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-memory-consolidation-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Long-term Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "")
    Application.put_env(:nex_agent, :workspace_path, workspace)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "consolidation fails when save_memory payload is missing required fields", %{
    workspace: workspace
  } do
    session = build_session()

    assert {:error, reason} =
             Memory.consolidate(session, :anthropic, "claude-sonnet-4-20250514",
               archive_all: true,
               workspace: workspace,
               llm_call_fun: fn _, _ -> {:ok, %{"history_entry" => "history only"}} end
             )

    assert reason =~ "memory_update"
    assert File.read!(Path.join(workspace, "memory/HISTORY.md")) == ""
    assert Memory.read_long_term(workspace: workspace) == "# Long-term Memory\n"
  end

  test "consolidation accepts list-wrapped save_memory payloads", %{workspace: workspace} do
    session = build_session()

    assert {:ok, updated_session} =
             Memory.consolidate(session, :anthropic, "claude-sonnet-4-20250514",
               archive_all: true,
               workspace: workspace,
               llm_call_fun: fn _, _ ->
                 {:ok,
                  [
                    %{
                      "history_entry" => "[2026-03-18 10:00] Captured a durable fact.",
                      "memory_update" => "# Long-term Memory\n\nCaptured fact.\n"
                    }
                  ]}
               end
             )

    assert updated_session.last_consolidated == length(session.messages)
    assert File.read!(Path.join(workspace, "memory/HISTORY.md")) =~ "Captured a durable fact"
    assert Memory.read_long_term(workspace: workspace) =~ "Captured fact"
  end

  test "consolidation works without tool_choice for anthropic provider", %{
    workspace: workspace
  } do
    parent = self()
    session = build_session()

    llm_generate_text_fun = fn _model_spec, _messages, opts ->
      send(parent, {:llm_opts, opts})

      # No retry needed - tool_choice is nil
      {:ok,
       %{
         tool_calls: [
           %{
             function: %{
               name: "save_memory",
               arguments: %{
                 "history_entry" =>
                   "[2026-03-18 12:00] Consolidated without tool_choice.",
                 "memory_update" =>
                   "# Long-term Memory\n\nConsolidation succeeded.\n"
               }
             }
           }
         ]
       }}
    end

    assert {:ok, updated_session} =
             Memory.consolidate(session, :anthropic, "claude-sonnet-4-20250514",
               archive_all: true,
               workspace: workspace,
               llm_call_fun: &Runner.call_llm_for_consolidation/2,
               req_llm_generate_text_fun: llm_generate_text_fun
             )

    assert_receive {:llm_opts, opts}
    # tool_choice is now nil for all providers
    refute opts[:tool_choice]
    assert updated_session.last_consolidated == length(session.messages)

    assert File.read!(Path.join(workspace, "memory/HISTORY.md")) =~
             "Consolidated without tool_choice"

    assert Memory.read_long_term(workspace: workspace) =~ "Consolidation succeeded"
  end

  defp build_session do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %Session{
      key: "memory-consolidation",
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      metadata: %{},
      last_consolidated: 0,
      messages: [
        %{"role" => "user", "content" => "first", "timestamp" => now},
        %{"role" => "assistant", "content" => "second", "timestamp" => now}
      ]
    }
  end
end
