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

    test "triggered consolidation evolution preserves runtime llm opts", %{workspace: workspace} do
      parent = self()

      Enum.each(1..4, fn _ ->
        refute Evolution.maybe_trigger_after_consolidation(workspace: workspace)
      end)

      assert Evolution.maybe_trigger_after_consolidation(
               workspace: workspace,
               provider: :anthropic,
               model: "kimi-k2.5",
               api_key: "test-api-key",
               base_url: "https://moonshot.example.test/anthropic",
               llm_call_fun: fn _messages, llm_opts ->
                 send(parent, {:evolution_llm_opts, llm_opts})
                 {:ok, %{"observations" => "ok"}}
               end
             )

      assert_receive {:evolution_llm_opts, llm_opts}, 500
      assert llm_opts[:provider] == :anthropic
      assert llm_opts[:model] == "kimi-k2.5"
      assert llm_opts[:api_key] == "test-api-key"
      assert llm_opts[:base_url] == "https://moonshot.example.test/anthropic"

      assert wait_until(fn ->
               Enum.any?(Evolution.recent_events(workspace: workspace), fn event ->
                 event["event"] == "evolution.cycle_completed"
               end)
             end)
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
                 trigger: :manual,
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
                 trigger: :manual,
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
                 trigger: :manual,
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
                 trigger: :scheduled_weekly,
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
                 trigger: :manual,
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
                 trigger: :manual,
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
                 trigger: :manual,
                 llm_call_fun: llm_call_fun
               )
    end

    test "trigger profiles select expected instructions and history windows", %{
      workspace: workspace
    } do
      history =
        1..12
        |> Enum.map_join("\n\n", fn n ->
          "[2026-03-20 #{String.pad_leading(Integer.to_string(n), 2, "0")}:00] Paragraph #{n}."
        end)

      File.write!(Path.join(workspace, "memory/HISTORY.md"), history)

      manual_prompt = capture_prompt(workspace, :manual)
      scheduled_daily_prompt = capture_prompt(workspace, :scheduled_daily)
      post_consolidation_prompt = capture_prompt(workspace, :post_consolidation)
      scheduled_weekly_prompt = capture_prompt(workspace, :scheduled_weekly)

      assert manual_prompt =~ "Analyze the last day of activity"
      assert manual_prompt =~ "Paragraph 3."
      assert manual_prompt =~ "Paragraph 12."
      refute manual_prompt =~ "Paragraph 1."
      refute manual_prompt =~ "Paragraph 2."

      assert scheduled_daily_prompt =~ "Analyze the last day of activity"
      assert scheduled_daily_prompt =~ "Paragraph 3."
      assert scheduled_daily_prompt =~ "Paragraph 12."
      refute scheduled_daily_prompt =~ "Paragraph 1."
      refute scheduled_daily_prompt =~ "Paragraph 2."

      assert post_consolidation_prompt =~ "Focus on the most recent conversation segment only"
      assert post_consolidation_prompt =~ "Paragraph 10."
      assert post_consolidation_prompt =~ "Paragraph 12."
      refute post_consolidation_prompt =~ "Paragraph 9."

      assert scheduled_weekly_prompt =~
               "Deep analysis of all history. Look for recurring patterns"

      assert scheduled_weekly_prompt =~ "Paragraph 1."
      assert scheduled_weekly_prompt =~ "Paragraph 12."
    end
  end

  describe "recent_events/1" do
    test "returns only evolution events", %{workspace: workspace} do
      Nex.Agent.Audit.append(
        "evolution.cycle_started",
        %{trigger: "manual", profile: "routine"},
        workspace: workspace
      )

      Nex.Agent.Audit.append("other.event", %{data: "test"}, workspace: workspace)

      Nex.Agent.Audit.append("evolution.cycle_completed", %{soul_updates: 1},
        workspace: workspace
      )

      events = Evolution.recent_events(workspace: workspace)
      assert length(events) == 2
      assert Enum.all?(events, fn e -> String.starts_with?(e["event"], "evolution.") end)
    end
  end

  defp capture_prompt(workspace, trigger) do
    parent = self()

    llm_call_fun = fn messages, _opts ->
      user_message = Enum.find(messages, &(&1["role"] == "user"))
      send(parent, {:evolution_prompt, trigger, user_message["content"]})
      {:ok, %{"observations" => "ok"}}
    end

    assert {:ok, _result} =
             Evolution.run_evolution_cycle(
               workspace: workspace,
               trigger: trigger,
               llm_call_fun: llm_call_fun
             )

    assert_receive {:evolution_prompt, ^trigger, prompt}, 500
    prompt
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end
end
