defmodule Nex.Agent.MemoryAuditTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.ContextBuilder
  alias Nex.Agent.Memory
  alias Nex.Agent.Memory.Index
  alias Nex.Agent.Runner
  alias Nex.Agent.Session

  @memory_dir Path.join(Memory.workspace_path(), "memory")

  setup_all do
    ensure_started(Index, fn -> Index.start_link() end)

    backup_dir =
      Path.join(System.tmp_dir!(), "nex_agent_memory_audit_backup_#{System.unique_integer([:positive])}")

    original_exists = File.exists?(@memory_dir)

    if original_exists do
      {:ok, _files} = File.cp_r(@memory_dir, backup_dir)
    end

    reset_memory_dir()
    Memory.reindex()

    on_exit(fn ->
      File.rm_rf(@memory_dir)

      if original_exists do
        {:ok, _files} = File.cp_r(backup_dir, @memory_dir)
      else
        File.mkdir_p!(@memory_dir)
      end

      File.rm_rf(backup_dir)
      Memory.reindex()
    end)

    :ok
  end

  setup do
    reset_memory_dir()
    Memory.reindex()
    :ok
  end

  describe "session parity characterization" do
    test "strips unmatched tool calls to keep provider-safe history" do
      session =
        Session.new("audit:tool-pairs")
        |> put_messages([
          %{
            "role" => "user",
            "content" => "find issue"
          },
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{"id" => "call_1", "function" => %{"name" => "read", "arguments" => %{"path" => "a.ex"}}},
              %{"id" => "call_2", "function" => %{"name" => "read", "arguments" => %{"path" => "b.ex"}}}
            ]
          },
          %{
            "role" => "tool",
            "tool_call_id" => "call_1",
            "name" => "read",
            "content" => "contents"
          }
        ])

      history = Session.get_history(session, 10)

      assert [
               %{"role" => "user"},
               %{"role" => "assistant", "tool_calls" => [%{"id" => "call_1"}]},
               %{"role" => "tool", "tool_call_id" => "call_1"}
             ] = history
    end
  end

  describe "memory file parsing" do
    test "read_memory_sections indexes unheaded MEMORY.md content as an implicit section" do
      File.write!(Path.join(@memory_dir, "MEMORY.md"), "plain memory without markdown headings")

      assert [%{header: "General", content: "plain memory without markdown headings"}] =
               Memory.read_memory_sections()

      assert Memory.get_memory_context() =~ "plain memory without markdown headings"

      Memory.reindex()
      assert [%{source: :memory}] = Memory.search("plain", source: :memory, limit: 5)
    end
  end

  describe "index consistency" do
    test "write_long_term refreshes memory index immediately" do
      File.write!(Path.join(@memory_dir, "MEMORY.md"), "## Topic\nalpha alpha alpha")
      Memory.reindex()

      assert [%{source: :memory}] = Memory.search("alpha", source: :memory, limit: 5)

      Memory.write_long_term("## Topic\nbeta beta beta")

      assert [%{source: :memory}] = Memory.search("beta", source: :memory, limit: 5)
    end

    test "append_history refreshes history index immediately" do
      Memory.append_history("[2026-03-10 10:00] shipped widget audit trail")
      assert [%{source: :history}] = Memory.search("widget", source: :history, limit: 5)

      Memory.append_history("[2026-03-10 11:00] post deploy followup")

      assert [%{source: :history}] = Memory.search("followup", source: :history, limit: 5)
    end
  end

  describe "store format" do
    test "store writes entries that can be parsed and searched back" do
      :ok = Memory.store(%{type: "audit", note: "remember this"})

      assert [%{task: "STORE audit", result: "STORED"} = entry] = Memory.read_all_entries()
      assert entry.body =~ "remember this"
      assert [%{source: :daily}] = Memory.search("remember", source: :daily, limit: 5)
    end
  end

  describe "context injection" do
    test "memory-only search results are not duplicated into relevant memories" do
      File.write!(Path.join(@memory_dir, "MEMORY.md"), "## ProjectX\nprojectx projectx projectx")
      Memory.reindex()

      assert [%{source: :memory}] = Memory.search("projectx", source: :memory, limit: 5)

      [system | _rest] = ContextBuilder.build_messages([], "projectx", nil, nil, nil, workspace: Memory.workspace_path())
      content = system["content"]

      assert content =~ "## Long-term Memory"
      assert content =~ "projectx projectx projectx"
      refute content =~ "## Relevant Memories"
    end

    test "truncated memory can still surface through relevant memories" do
      large_prefix = String.duplicate("intro ", 1400)
      hidden_tail = "tailneedle tailneedle tailneedle"
      File.write!(Path.join(@memory_dir, "MEMORY.md"), "## ProjectX\n#{large_prefix}\n#{hidden_tail}")
      Memory.reindex()

      [system | _rest] =
        ContextBuilder.build_messages([], "tailneedle", nil, nil, nil,
          workspace: Memory.workspace_path()
        )

      content = system["content"]

      assert content =~ "## Long-term Memory"
      assert content =~ "## Relevant Memories"
      assert content =~ "[memory]"
    end
  end

  describe "consolidation compatibility" do
    test "runner parses list-wrapped tool arguments like nanobot" do
      assert %{"history_entry" => "ok"} =
               Runner.parse_tool_arguments([%{"history_entry" => "ok"}])
    end

    test "consolidate advances session when only history entry is returned" do
      session =
        Session.new("audit:consolidate-history")
        |> put_messages(sample_messages())

      {:ok, updated} =
        Memory.consolidate(session, :openai, "test-model",
          memory_window: 4,
          llm_call_fun: fn _messages, _opts ->
            {:ok, %{"history_entry" => "[2026-03-10 10:00] summarized only"}}
          end
        )

      assert updated.last_consolidated == length(session.messages) - 2
      assert Enum.any?(Memory.read_history(), &String.contains?(&1.content, "summarized only"))
    end

    test "consolidate accepts non-string memory updates and persists them" do
      session =
        Session.new("audit:consolidate-memory")
        |> put_messages(sample_messages())

      {:ok, updated} =
        Memory.consolidate(session, :openai, "test-model",
          memory_window: 4,
          llm_call_fun: fn _messages, _opts ->
            {:ok,
             %{
               "memory_update" => %{"summary" => "normalized"},
               "user_preferences" => []
             }}
          end
        )

      assert updated.last_consolidated == length(session.messages) - 2
      assert Memory.read_long_term() =~ "\"summary\":\"normalized\""
    end
  end

  defp put_messages(session, messages) do
    %{session | messages: messages}
  end

  defp reset_memory_dir do
    File.rm_rf(@memory_dir)
    File.mkdir_p!(@memory_dir)
    File.write!(Path.join(@memory_dir, "MEMORY.md"), "")
    File.write!(Path.join(@memory_dir, "HISTORY.md"), "")
  end

  defp sample_messages do
    [
      %{"role" => "user", "content" => "one"},
      %{"role" => "assistant", "content" => "two"},
      %{"role" => "user", "content" => "three"},
      %{"role" => "assistant", "content" => "four"},
      %{"role" => "user", "content" => "five"},
      %{"role" => "assistant", "content" => "six"}
    ]
  end

  defp ensure_started(name, start_fun) do
    unless Process.whereis(name) do
      start_fun.()
    end
  end
end
