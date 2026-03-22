defmodule Nex.Agent.EvolutionIntegrationTest do
  @moduledoc """
  End-to-end integration test for the evolution closed loop:

    User conversation → Runner records signals → Memory consolidation triggers evolution
    → LLM reflection → SOUL.md / MEMORY.md / Skills updated → Audit trail written

  Uses mock LLM throughout, no network required.
  """
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Evolution, Memory, Runner, Session, Skills}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-evo-integ-#{System.unique_integer([:positive])}")

    for dir <- ~w(memory skills audit sessions) do
      File.mkdir_p!(Path.join(workspace, dir))
    end

    File.write!(
      Path.join(workspace, "SOUL.md"),
      "# Soul\n\n## Values\n- Be helpful\n- Be concise\n"
    )

    File.write!(Path.join(workspace, "memory/MEMORY.md"), "")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "")

    Application.put_env(:nex_agent, :workspace_path, workspace)

    for {mod, name} <- [
          {Task.Supervisor, Nex.Agent.TaskSupervisor},
          {Bus, Bus},
          {Nex.Agent.Tool.Registry, Nex.Agent.Tool.Registry}
        ] do
      if Process.whereis(name) == nil do
        start_supervised!({mod, name: name})
      end
    end

    if Process.whereis(Skills) == nil do
      start_supervised!({Skills, []})
    end

    Skills.load()

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      # Small delay to let any async evolution tasks finish before cleanup
      Process.sleep(200)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "full closed loop: corrections → signals → evolution → soul/memory/skill updates", %{
    workspace: workspace
  } do
    # ──────────────────────────────────────────────────────────
    # Step 1: Simulate several conversations where the user
    #         corrects the agent. This should record signals.
    # ──────────────────────────────────────────────────────────

    llm_client = fn _messages, _opts ->
      {:ok, %{content: "好的", finish_reason: nil, tool_calls: []}}
    end

    # "不对" and "应该" are in @user_correction_terms
    correction_prompts = [
      "不对，应该用 JSON 格式返回",
      "改成 snake_case 命名",
      "actually use PostgreSQL not MySQL"
    ]

    _final_session =
      Enum.reduce(correction_prompts, Session.new("evo-integ"), fn prompt, session ->
        {:ok, _result, updated} =
          Runner.run(session, prompt,
            llm_client: llm_client,
            workspace: workspace,
            skip_consolidation: true
          )

        updated
      end)

    # Verify: signals were recorded
    signals = Evolution.read_signals(workspace: workspace)
    assert length(signals) >= 2, "Expected at least 2 correction signals, got #{length(signals)}"

    # Verify signals contain correction info before evolution
    assert Enum.any?(signals, fn s ->
             s["source"] == "runner" and String.contains?(s["signal"], "correction")
           end)

    # Verify signal content will be visible to the evolution LLM
    signals_text =
      signals
      |> Enum.map(fn s -> Map.get(s, "signal", "") end)
      |> Enum.join(" ")

    assert signals_text =~ "correction"

    # ──────────────────────────────────────────────────────────
    # Step 2: Run evolution cycle with a mock LLM that returns
    #         soul updates, memory updates, and a skill draft.
    # ──────────────────────────────────────────────────────────

    evolution_llm = fn messages, _opts ->
      # Verify the evolution prompt contains context sections
      user_msg = Enum.find(messages, &(&1["role"] == "user"))
      assert user_msg["content"] =~ "Accumulated Signals"

      {:ok,
       %{
         "observations" =>
           "User corrected output format 3 times. Consistent preference for JSON and snake_case.",
         "soul_updates" => [
           "Default to JSON format for structured output unless user specifies otherwise",
           "Use snake_case naming in all code generation"
         ],
         "memory_updates" => [
           "User prefers PostgreSQL over MySQL for database projects."
         ],
         "skill_candidates" => [
           %{
             "name" => "format_json_output",
             "description" => "Format tool results as JSON",
             "content" => "When returning structured data, always wrap in ```json blocks."
           }
         ],
         "code_upgrade_hints" => [
           "Consider adding a default output format config to Runner"
         ]
       }}
    end

    {:ok, result} =
      Evolution.run_evolution_cycle(
        workspace: workspace,
        trigger: :manual,
        llm_call_fun: evolution_llm
      )

    assert result.soul_updates == 2
    assert result.memory_updates == 1
    assert result.skill_candidates == 1

    # ──────────────────────────────────────────────────────────
    # Step 3: Verify all downstream effects
    # ──────────────────────────────────────────────────────────

    # 3a. SOUL.md was updated with new principles
    soul = File.read!(Path.join(workspace, "SOUL.md"))
    assert soul =~ "Evolved Principles"
    assert soul =~ "JSON format"
    assert soul =~ "snake_case"
    # Original values preserved
    assert soul =~ "Be helpful"
    assert soul =~ "Be concise"

    # 3b. MEMORY.md was updated with new fact
    memory = Memory.read_long_term(workspace: workspace)
    assert memory =~ "PostgreSQL"

    # 3c. Skill draft was created
    skill_path = Path.join(workspace, "skills/format_json_output/SKILL.md")
    assert File.exists?(skill_path), "Draft skill file should exist"
    skill_content = File.read!(skill_path)
    assert skill_content =~ "status: draft"
    assert skill_content =~ "json blocks"

    # 3d. Audit trail has evolution events
    events = Evolution.recent_events(workspace: workspace)
    event_types = Enum.map(events, & &1["event"])
    assert "evolution.cycle_started" in event_types
    assert "evolution.cycle_completed" in event_types
    assert "evolution.soul_updated" in event_types
    assert "evolution.memory_updated" in event_types
    assert "evolution.skill_drafted" in event_types
    assert "evolution.code_hint" in event_types

    completed_event = Enum.find(events, &(&1["event"] == "evolution.cycle_completed"))
    assert completed_event["payload"]["trigger"] == "manual"
    assert completed_event["payload"]["profile"] == "routine"

    # 3e. Signals were consumed (cleared after cycle)
    assert Evolution.read_signals(workspace: workspace) == []

    # ──────────────────────────────────────────────────────────
    # Step 4: Verify idempotency — running again with same
    #         updates should not duplicate.
    # ──────────────────────────────────────────────────────────

    {:ok, result2} =
      Evolution.run_evolution_cycle(
        workspace: workspace,
        trigger: :manual,
        llm_call_fun: evolution_llm
      )

    # Soul principles already exist → should be 0 (dedup works)
    assert result2.soul_updates == 0

    # SOUL.md should NOT have duplicate "Evolved Principles" sections
    soul_after = File.read!(Path.join(workspace, "SOUL.md"))

    assert length(String.split(soul_after, "Evolved Principles")) == 2,
           "Should have exactly one 'Evolved Principles' section, not duplicates"
  end

  test "consolidation counter triggers evolution at threshold", %{workspace: workspace} do
    # Simulate 4 consolidations — should not trigger
    for _ <- 1..4 do
      refute Evolution.maybe_trigger_after_consolidation(workspace: workspace)
    end

    # 5th consolidation triggers
    assert Evolution.maybe_trigger_after_consolidation(workspace: workspace)

    # Wait briefly for the async task to start (it will fail due to no API key, that's fine)
    Process.sleep(100)

    # Counter continues
    for _ <- 1..4 do
      refute Evolution.maybe_trigger_after_consolidation(workspace: workspace)
    end

    # 10th consolidation triggers again
    assert Evolution.maybe_trigger_after_consolidation(workspace: workspace)
  end

  test "Memory.consolidate hooks into evolution counter", %{workspace: workspace} do
    counter_path = Path.join(workspace, "memory/.evolution_counter")

    # Clear counter
    File.rm(counter_path)

    session = %Session{
      key: "evo-consolidation-test",
      messages: [
        %{"role" => "user", "content" => "hello", "timestamp" => "2026-03-20T10:00:00Z"},
        %{"role" => "assistant", "content" => "hi there", "timestamp" => "2026-03-20T10:01:00Z"}
      ],
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      metadata: %{},
      last_consolidated: 0
    }

    mock_llm_call = fn _messages, _opts ->
      {:ok,
       %{
         "history_entry" => "[2026-03-20 10:00] Test conversation.",
         "memory_update" => "# Memory\nTest fact.\n"
       }}
    end

    {:ok, _updated} =
      Memory.consolidate(session, :anthropic, "test-model",
        workspace: workspace,
        archive_all: true,
        llm_call_fun: mock_llm_call
      )

    # Counter should have been incremented
    assert File.read!(counter_path) |> String.trim() == "1"

    # History should be written
    history = File.read!(Path.join(workspace, "memory/HISTORY.md"))
    assert history =~ "Test conversation"
  end

  test "reflect tool evolution_status works end-to-end", %{workspace: workspace} do
    # Record some signals
    Evolution.record_signal(
      %{source: "runner", signal: "User corrected format"},
      workspace: workspace
    )

    # Run a cycle to generate audit events
    mock_llm = fn _messages, _opts ->
      {:ok, %{"observations" => "Minor patterns."}}
    end

    Evolution.run_evolution_cycle(
      workspace: workspace,
      trigger: :manual,
      llm_call_fun: mock_llm
    )

    # Record a new signal after cycle
    Evolution.record_signal(
      %{source: "test", signal: "New signal after cycle"},
      workspace: workspace
    )

    # Call reflect tool
    ctx = %{workspace: workspace}
    {:ok, status} = Nex.Agent.Tool.Reflect.execute(%{"action" => "evolution_status"}, ctx)

    assert status =~ "Evolution Status"
    assert status =~ "evolution.cycle"
    assert status =~ "1 pending signal"

    # Check evolution_history
    {:ok, history} = Nex.Agent.Tool.Reflect.execute(%{"action" => "evolution_history"}, ctx)
    assert history =~ "Cycle Completed"
  end
end
