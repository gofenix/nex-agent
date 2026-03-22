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

    :ok = Session.save(session, workspace: workspace)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      SessionManager.invalidate(key, workspace: workspace)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, key: key}
  end

  test "memory_rebuild performs archive_all consolidation and persists progress", %{
    workspace: workspace,
    key: key
  } do
    File.write!(
      Path.join(workspace, "memory/MEMORY.md"),
      "# Long-term Memory\n\n## Existing Facts\nExisting workspace memory should not seed rebuild batches.\n"
    )

    parent = self()
    Process.delete(:memory_rebuild_batch)

    llm_call_fun = fn messages, _opts ->
      prompt_memory = prompt_memory_block(messages)
      send(parent, {:prompt_memory, prompt_memory})

      batch = Process.get(:memory_rebuild_batch, 0) + 1
      Process.put(:memory_rebuild_batch, batch)

      memory_update =
        case batch do
          1 ->
            "# Long-term Memory\n\n## Rebuilt Facts\nBatch 1 fact.\n"

          _ ->
            assert prompt_memory =~ "Batch 1 fact."
            refute prompt_memory =~ "Existing workspace memory should not seed rebuild batches."
            "# Long-term Memory\n\n## Rebuilt Facts\nBatch 1 fact.\nBatch 2 fact.\n"
        end

      {:ok,
       %{
         "history_entry" => "[2026-03-15 11:0#{batch}] Rebuilt batch #{batch}.",
         "memory_update" => memory_update
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

    assert_receive {:prompt_memory, "(empty)"}
    assert_receive {:prompt_memory, second_prompt}
    assert second_prompt =~ "Batch 1 fact."
    refute second_prompt =~ "Existing workspace memory should not seed rebuild batches."

    assert result["session_key"] == key
    assert result["processed_messages"] == 4
    assert result["batches_processed"] == 2
    assert result["batch_messages"] == 2
    assert result["last_consolidated_before"] == 1
    assert result["last_consolidated_after"] == 4

    reloaded = Session.load(key, workspace: workspace)
    assert reloaded.last_consolidated == 4
    assert Memory.read_long_term(workspace: workspace) =~ "Batch 2 fact."

    refute Memory.read_long_term(workspace: workspace) =~
             "Existing workspace memory should not seed rebuild batches."

    history = File.read!(Path.join(workspace, "memory/HISTORY.md"))
    assert history =~ "Rebuilt batch 1."
    assert history =~ "Rebuilt batch 2."
  end

  test "memory_rebuild leaves workspace memory and history untouched when a later batch fails", %{
    workspace: workspace,
    key: key
  } do
    original_memory =
      "# Long-term Memory\n\n## Existing Facts\nOriginal memory must survive failed rebuilds.\n"

    original_history =
      "# Conversation History Log\n\n[2026-03-15 09:00] Original history must survive failed rebuilds.\n"

    File.write!(Path.join(workspace, "memory/MEMORY.md"), original_memory)
    File.write!(Path.join(workspace, "memory/HISTORY.md"), original_history)
    parent = self()
    Process.delete(:memory_rebuild_failure_batch)

    assert {:error, "moonshot empty body"} =
             MemoryRebuild.execute(
               %{},
               %{
                 workspace: workspace,
                 session_key: key,
                 provider: :anthropic,
                 model: "claude-sonnet-4-20250514",
                 llm_call_fun: fn messages, _opts ->
                   prompt_memory = prompt_memory_block(messages)
                   send(parent, {:prompt_memory, prompt_memory})

                   batch = Process.get(:memory_rebuild_failure_batch, 0) + 1
                   Process.put(:memory_rebuild_failure_batch, batch)

                   case batch do
                     1 ->
                       {:ok,
                        %{
                          "history_entry" => "[2026-03-15 12:00] Temporary rebuild batch 1.",
                          "memory_update" =>
                            "# Long-term Memory\n\n## Rebuilt Facts\nTemporary rebuild fact.\n"
                        }}

                     _ ->
                       {:error, "moonshot empty body"}
                   end
                 end,
                 batch_messages: 2
               }
             )

    assert_receive {:prompt_memory, "(empty)"}
    assert_receive {:prompt_memory, second_prompt}
    assert second_prompt =~ "Temporary rebuild fact."
    refute second_prompt =~ "Original memory must survive failed rebuilds."

    assert Memory.read_long_term(workspace: workspace) == original_memory
    assert File.read!(Path.join(workspace, "memory/HISTORY.md")) == original_history

    reloaded = Session.load(key, workspace: workspace)
    assert reloaded.last_consolidated == 1
  end

  test "memory_rebuild retries with empty memory context on anthropic decode errors", %{
    workspace: workspace,
    key: key
  } do
    parent = self()
    Process.delete(:memory_rebuild_retry_step)

    assert {:ok, result} =
             MemoryRebuild.execute(
               %{},
               %{
                 workspace: workspace,
                 session_key: key,
                 provider: :anthropic,
                 model: "claude-sonnet-4-20250514",
                 llm_call_fun: fn messages, _opts ->
                   prompt_memory = prompt_memory_block(messages)
                   send(parent, {:prompt_memory, prompt_memory})

                   case Process.get(:memory_rebuild_retry_step, 0) do
                     0 ->
                       Process.put(:memory_rebuild_retry_step, 1)

                       {:ok,
                        %{
                          "history_entry" => "[2026-03-15 13:00] Rebuild batch 1.",
                          "memory_update" =>
                            "# Long-term Memory\n\n## Rebuilt Facts\nBatch 1 fact.\n"
                        }}

                     1 ->
                       Process.put(:memory_rebuild_retry_step, 2)

                       {:error,
                        %{
                          reason:
                            "Anthropic response decode error (empty_body): reason=:not_implemented body_type=:binary body_bytes=0"
                        }}

                     _ ->
                       assert prompt_memory == "(empty)"

                       {:ok,
                        %{
                          "history_entry" =>
                            "[2026-03-15 13:01] Rebuild batch 2 recovered via fallback.",
                          "memory_update" =>
                            "# Long-term Memory\n\n## Rebuilt Facts\nBatch 1 fact.\nBatch 2 fact.\n"
                        }}
                   end
                 end,
                 batch_messages: 2
               }
             )

    assert_receive {:prompt_memory, "(empty)"}
    assert_receive {:prompt_memory, second_prompt}
    assert second_prompt =~ "Batch 1 fact."
    assert_receive {:prompt_memory, "(empty)"}

    assert result["last_consolidated_after"] == 4
    assert Memory.read_long_term(workspace: workspace) =~ "Batch 2 fact."

    history = File.read!(Path.join(workspace, "memory/HISTORY.md"))
    assert history =~ "Rebuild batch 1."
    assert history =~ "recovered via fallback"
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

  defp prompt_memory_block(messages) do
    prompt = List.last(messages)["content"]

    [_, block] =
      Regex.run(~r/## Current Long-term Memory\n(.+?)\n\n## Conversation to Process/s, prompt)

    String.trim(block)
  end
end
