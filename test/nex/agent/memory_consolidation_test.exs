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

  test "consolidation raw-archives after three failed save_memory payloads", %{
    workspace: workspace
  } do
    session = build_session()

    failing_call = fn _, _ -> {:ok, %{"history_entry" => "history only"}} end

    assert {:error, reason} =
             Memory.consolidate(session, :anthropic, "claude-sonnet-4-20250514",
               archive_all: true,
               workspace: workspace,
               llm_call_fun: failing_call
             )

    assert reason =~ "memory_update"

    assert {:error, reason} =
             Memory.consolidate(session, :anthropic, "claude-sonnet-4-20250514",
               archive_all: true,
               workspace: workspace,
               llm_call_fun: failing_call
             )

    assert reason =~ "memory_update"

    assert {:ok, updated_session} =
             Memory.consolidate(session, :anthropic, "claude-sonnet-4-20250514",
               archive_all: true,
               workspace: workspace,
               llm_call_fun: failing_call
             )

    assert updated_session.last_consolidated == length(session.messages)
    history = File.read!(Path.join(workspace, "memory/HISTORY.md"))
    assert history =~ "[RAW] 2 messages"
    assert history =~ "USER: first"
    assert history =~ "ASSISTANT: second"
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

  test "consolidation forces save_memory tool_choice", %{
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
                 "history_entry" => "[2026-03-18 12:00] Consolidated without tool_choice.",
                 "memory_update" => "# Long-term Memory\n\nConsolidation succeeded.\n"
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
    assert opts[:tool_choice] == %{type: "function", function: %{name: "save_memory"}}
    assert updated_session.last_consolidated == length(session.messages)

    assert File.read!(Path.join(workspace, "memory/HISTORY.md")) =~
             "Consolidated without tool_choice"

    assert Memory.read_long_term(workspace: workspace) =~ "Consolidation succeeded"
  end

  test "template-only memory compacts to empty prompt context without rewriting MEMORY.md", %{
    workspace: workspace
  } do
    template = template_memory()
    File.write!(Path.join(workspace, "memory/MEMORY.md"), template)
    parent = self()
    session = build_session()

    assert {:ok, _updated_session} =
             Memory.consolidate(session, :anthropic, "claude-sonnet-4-20250514",
               archive_all: true,
               workspace: workspace,
               llm_call_fun: fn messages, _opts ->
                 send(parent, {:prompt_memory, prompt_memory_block(messages)})

                 {:ok,
                  %{
                    "history_entry" => "[2026-03-22 10:00] Template-only memory stayed empty.",
                    "memory_update" => template
                  }}
               end
             )

    assert_receive {:prompt_memory, "(empty)"}
    assert Memory.read_long_term(workspace: workspace) == template
  end

  test "substantive memory survives prompt compaction while boilerplate is stripped", %{
    workspace: workspace
  } do
    memory = substantive_memory()
    File.write!(Path.join(workspace, "memory/MEMORY.md"), memory)
    parent = self()
    session = build_session()

    assert {:ok, _updated_session} =
             Memory.consolidate(session, :anthropic, "claude-sonnet-4-20250514",
               archive_all: true,
               workspace: workspace,
               llm_call_fun: fn messages, _opts ->
                 send(parent, {:prompt_memory, prompt_memory_block(messages)})

                 {:ok,
                  %{
                    "history_entry" => "[2026-03-22 10:05] Substantive memory was preserved.",
                    "memory_update" => memory
                  }}
               end
             )

    assert_receive {:prompt_memory, prompt_memory}

    assert prompt_memory =~
             "Moonshot compatibility failures were traced to full MEMORY.md prompt echoing."

    refute prompt_memory =~ "This file stores important facts that persist across conversations."
    refute prompt_memory =~ "## Environment Facts"
  end

  test "consolidation retries once with empty memory context on anthropic decode errors", %{
    workspace: workspace
  } do
    File.write!(Path.join(workspace, "memory/MEMORY.md"), substantive_memory())
    parent = self()
    session = build_session()
    Process.delete(:memory_consolidation_retry_count)

    assert {:ok, updated_session} =
             Memory.consolidate(session, :anthropic, "claude-sonnet-4-20250514",
               archive_all: true,
               workspace: workspace,
               llm_call_fun: fn messages, _opts ->
                 prompt_memory = prompt_memory_block(messages)
                 send(parent, {:prompt_memory, prompt_memory})

                 case Process.get(:memory_consolidation_retry_count, 0) do
                   0 ->
                     Process.put(:memory_consolidation_retry_count, 1)

                     {:error,
                      %{
                        reason:
                          "Anthropic response decode error (empty_body): reason=:not_implemented body_type=:binary body_bytes=0"
                      }}

                   _ ->
                     {:ok,
                      %{
                        "history_entry" =>
                          "[2026-03-22 10:10] Empty-memory fallback recovered Moonshot consolidation.",
                        "memory_update" =>
                          "# Long-term Memory\n\n## Recovered Facts\nFallback path succeeded.\n"
                      }}
                 end
               end
             )

    assert_receive {:prompt_memory, first_prompt}
    assert first_prompt =~ "Moonshot compatibility failures were traced"
    assert_receive {:prompt_memory, "(empty)"}
    assert updated_session.last_consolidated == length(session.messages)
    assert Memory.read_long_term(workspace: workspace) =~ "Fallback path succeeded"
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

  defp prompt_memory_block(messages) do
    prompt = List.last(messages)["content"]

    [_, block] =
      Regex.run(~r/## Current Long-term Memory\n(.+?)\n\n## Conversation to Process/s, prompt)

    String.trim(block)
  end

  defp template_memory do
    """
    # Long-term Memory

    This file stores important facts that persist across conversations.

    ## Environment Facts

    (Stable facts about runtime, infrastructure, and toolchain)

    ## Project Conventions

    (Important project-specific conventions and decisions)

    ## Project Context

    (Information about ongoing projects)

    ## Workflow Lessons

    (Reusable lessons learned from successful or failed execution paths)

    ---

    *This file is automatically updated when important information should be remembered.*
    """
  end

  defp substantive_memory do
    """
    # Long-term Memory

    This file stores important facts that persist across conversations.

    ## Environment Facts

    (Stable facts about runtime, infrastructure, and toolchain)

    ## Project Conventions

    (Important project-specific conventions and decisions)

    ## Durable Facts

    Moonshot compatibility failures were traced to full MEMORY.md prompt echoing.
    Keeping only substantive memory reduces the risk of empty Anthropic-compatible responses.

    ---

    *This file is automatically updated when important information should be remembered.*
    """
  end
end
