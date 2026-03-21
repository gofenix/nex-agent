defmodule Nex.Agent.EvolutionTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Evolution, Memory, Skills, Workspace}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-evolution-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    File.mkdir_p!(Path.join(workspace, "audit"))
    File.write!(Path.join(workspace, "SOUL.md"), "# Soul\n\n## Values\n- Be helpful\n")

    File.write!(
      Path.join(workspace, "memory/MEMORY.md"),
      "# Memory\nUser prefers concise replies.\n"
    )

    File.write!(
      Path.join(workspace, "memory/HISTORY.md"),
      "[2026-03-20 10:00] Helped user debug a deployment issue.\n\n[2026-03-20 14:00] User corrected output format twice.\n\n"
    )

    Application.put_env(:nex_agent, :workspace_path, workspace)

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Skills) == nil do
      start_supervised!({Skills, []})
    end

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  describe "record_signal/2" do
    test "writes signal to patterns.jsonl", %{workspace: workspace} do
      assert :ok =
               Evolution.record_signal(
                 %{
                   source: "runner",
                   signal: "User correction: fix format",
                   context: %{tool_errors: 0}
                 },
                 workspace: workspace
               )

      signals = Evolution.read_signals(workspace: workspace)
      assert length(signals) == 1
      assert hd(signals)["source"] == "runner"
      assert hd(signals)["signal"] == "User correction: fix format"
    end

    test "appends multiple signals", %{workspace: workspace} do
      Evolution.record_signal(%{source: "runner", signal: "correction 1"}, workspace: workspace)

      Evolution.record_signal(%{source: "consolidation", signal: "pattern detected"},
        workspace: workspace
      )

      signals = Evolution.read_signals(workspace: workspace)
      assert length(signals) == 2
    end
  end

  describe "clear_signals/1" do
    test "clears all accumulated signals", %{workspace: workspace} do
      Evolution.record_signal(%{source: "test", signal: "s1"}, workspace: workspace)
      Evolution.record_signal(%{source: "test", signal: "s2"}, workspace: workspace)

      assert length(Evolution.read_signals(workspace: workspace)) == 2

      Evolution.clear_signals(workspace: workspace)
      assert Evolution.read_signals(workspace: workspace) == []
    end
  end

  describe "maybe_trigger_after_consolidation/1" do
    test "does not trigger before threshold", %{workspace: workspace} do
      refute Evolution.maybe_trigger_after_consolidation(workspace: workspace)
      refute Evolution.maybe_trigger_after_consolidation(workspace: workspace)
      refute Evolution.maybe_trigger_after_consolidation(workspace: workspace)
      refute Evolution.maybe_trigger_after_consolidation(workspace: workspace)
    end

    test "triggers at threshold (every 5 consolidations)", %{workspace: workspace} do
      Enum.each(1..4, fn _ ->
        refute Evolution.maybe_trigger_after_consolidation(workspace: workspace)
      end)

      # 5th consolidation should trigger
      assert Evolution.maybe_trigger_after_consolidation(workspace: workspace)
    end

    test "counter persists across calls", %{workspace: workspace} do
      counter_path = Path.join(Workspace.memory_dir(workspace: workspace), ".evolution_counter")

      Enum.each(1..3, fn _ ->
        Evolution.maybe_trigger_after_consolidation(workspace: workspace)
      end)

      assert File.read!(counter_path) |> String.trim() == "3"
    end
  end

  describe "run_evolution_cycle/1" do
    test "completes with mock LLM returning empty report", %{workspace: workspace} do
      llm_call_fun = fn _messages, _opts ->
        {:ok,
         %{
           "observations" => "No significant patterns found.",
           "soul_updates" => [],
           "memory_updates" => [],
           "skill_candidates" => [],
           "code_upgrade_hints" => []
         }}
      end

      assert {:ok, result} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 scope: :daily,
                 llm_call_fun: llm_call_fun
               )

      assert result.soul_updates == 0
      assert result.memory_updates == 0
      assert result.skill_candidates == 0
    end

    test "applies soul updates from LLM report", %{workspace: workspace} do
      llm_call_fun = fn _messages, _opts ->
        {:ok,
         %{
           "observations" => "User frequently corrects output format.",
           "soul_updates" => ["Always format code blocks with language tags"],
           "memory_updates" => [],
           "skill_candidates" => [],
           "code_upgrade_hints" => []
         }}
      end

      assert {:ok, result} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 scope: :daily,
                 llm_call_fun: llm_call_fun
               )

      assert result.soul_updates == 1

      soul = File.read!(Path.join(workspace, "SOUL.md"))
      assert soul =~ "Evolved Principles"
      assert soul =~ "Always format code blocks with language tags"
    end

    test "applies memory updates from LLM report", %{workspace: workspace} do
      llm_call_fun = fn _messages, _opts ->
        {:ok,
         %{
           "observations" => "Learned new fact.",
           "soul_updates" => [],
           "memory_updates" => ["Project uses PostgreSQL 16."],
           "skill_candidates" => [],
           "code_upgrade_hints" => []
         }}
      end

      assert {:ok, result} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 scope: :daily,
                 llm_call_fun: llm_call_fun
               )

      assert result.memory_updates == 1

      memory = Memory.read_long_term(workspace: workspace)
      assert memory =~ "PostgreSQL 16"
    end

    test "creates draft skills from LLM report", %{workspace: workspace} do
      llm_call_fun = fn _messages, _opts ->
        {:ok,
         %{
           "observations" => "Deployment debugging pattern detected.",
           "soul_updates" => [],
           "memory_updates" => [],
           "skill_candidates" => [
             %{
               "name" => "debug_deploy",
               "description" => "Debug deployment issues",
               "content" => "1. Check logs\n2. Verify config\n3. Test connectivity"
             }
           ],
           "code_upgrade_hints" => []
         }}
      end

      assert {:ok, result} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 scope: :weekly,
                 llm_call_fun: llm_call_fun
               )

      assert result.skill_candidates == 1

      # Verify skill was created
      skill_file = Path.join(workspace, "skills/debug_deploy/SKILL.md")
      assert File.exists?(skill_file)
      content = File.read!(skill_file)
      assert content =~ "status: draft"
      assert content =~ "Check logs"
    end

    test "does not duplicate existing soul principles", %{workspace: workspace} do
      llm_call_fun = fn _messages, _opts ->
        {:ok,
         %{
           "observations" => "Repeated principle.",
           "soul_updates" => ["Be helpful"],
           "memory_updates" => [],
           "skill_candidates" => [],
           "code_upgrade_hints" => []
         }}
      end

      assert {:ok, result} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 scope: :daily,
                 llm_call_fun: llm_call_fun
               )

      # Should be 0 because "Be helpful" already exists in SOUL.md
      assert result.soul_updates == 0
    end

    test "clears signals after successful cycle", %{workspace: workspace} do
      Evolution.record_signal(%{source: "test", signal: "test signal"}, workspace: workspace)
      assert length(Evolution.read_signals(workspace: workspace)) == 1

      llm_call_fun = fn _messages, _opts ->
        {:ok, %{"observations" => "ok"}}
      end

      assert {:ok, _} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 scope: :daily,
                 llm_call_fun: llm_call_fun
               )

      assert Evolution.read_signals(workspace: workspace) == []
    end

    test "handles LLM failure gracefully", %{workspace: workspace} do
      llm_call_fun = fn _messages, _opts ->
        {:error, "API unavailable"}
      end

      assert {:error, {:llm_failed, "API unavailable"}} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 scope: :daily,
                 llm_call_fun: llm_call_fun
               )
    end
  end

  describe "recent_events/1" do
    test "returns only evolution events", %{workspace: workspace} do
      Nex.Agent.Audit.append("evolution.cycle_started", %{scope: "daily"}, workspace: workspace)
      Nex.Agent.Audit.append("other.event", %{data: "test"}, workspace: workspace)

      Nex.Agent.Audit.append("evolution.cycle_completed", %{soul_updates: 1},
        workspace: workspace
      )

      events = Evolution.recent_events(workspace: workspace)
      assert length(events) == 2
      assert Enum.all?(events, fn e -> String.starts_with?(e["event"], "evolution.") end)
    end
  end
end
