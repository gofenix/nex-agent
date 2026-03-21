defmodule Nex.Agent.OnboardingMigrationTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Onboarding

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "nex-agent-onboarding-#{System.unique_integer([:positive])}")

    config_path = Path.join(base_dir, "config.json")
    workspace = Path.join(base_dir, "workspace")

    File.mkdir_p!(Path.join(base_dir, "skills/legacy-skill"))
    File.mkdir_p!(Path.join(base_dir, "sessions/legacy-session"))
    File.mkdir_p!(Path.join(base_dir, "tools/legacy-tool"))

    File.write!(Path.join(base_dir, "skills/legacy-skill/SKILL.md"), "legacy skill\n")
    File.write!(Path.join(base_dir, "sessions/legacy-session/messages.jsonl"), "{}\n")

    File.write!(
      Path.join(base_dir, "tools/legacy-tool/tool.ex"),
      "defmodule LegacyTool do\nend\n"
    )

    File.mkdir_p!(Path.join(base_dir, "cron"))

    File.write!(
      Path.join(base_dir, "cron/jobs.json"),
      Jason.encode!([
        %{
          "id" => "legacy-cron-job",
          "name" => "legacy-daily-summary",
          "schedule" => %{"type" => "cron", "expr" => "0 21 * * *"},
          "message" => "legacy summary",
          "enabled" => true,
          "channel" => "feishu",
          "chat_id" => "ou_legacy",
          "delete_after_run" => false,
          "last_run" => nil,
          "next_run" => 1_700_000_000,
          "last_status" => nil,
          "last_error" => nil,
          "created_at" => 1_700_000_000,
          "updated_at" => 1_700_000_000
        }
      ])
    )

    File.mkdir_p!(Path.join(workspace, "skills/existing-skill"))
    File.mkdir_p!(Path.join(workspace, "sessions/existing-session"))
    File.mkdir_p!(Path.join(workspace, "tools/existing-tool"))
    File.mkdir_p!(Path.join(workspace, "tasks"))

    File.write!(Path.join(workspace, "skills/existing-skill/SKILL.md"), "existing skill\n")
    File.write!(Path.join(workspace, "sessions/existing-session/messages.jsonl"), "{}\n")

    File.write!(
      Path.join(workspace, "tools/existing-tool/tool.ex"),
      "defmodule ExistingTool do\nend\n"
    )

    File.write!(
      Path.join(workspace, "tasks/cron_jobs.json"),
      Jason.encode!([
        %{
          "id" => "current-cron-job",
          "name" => "current-weekly-summary",
          "schedule" => %{"type" => "cron", "expr" => "0 9 * * 1"},
          "message" => "current summary",
          "enabled" => true,
          "channel" => "feishu",
          "chat_id" => "ou_current",
          "delete_after_run" => false,
          "last_run" => nil,
          "next_run" => 1_700_100_000,
          "last_status" => nil,
          "last_error" => nil,
          "created_at" => 1_700_100_000,
          "updated_at" => 1_700_100_000
        }
      ])
    )

    Application.put_env(:nex_agent, :agent_base_dir, base_dir)
    Application.put_env(:nex_agent, :config_path, config_path)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :agent_base_dir)
      Application.delete_env(:nex_agent, :config_path)
      File.rm_rf!(base_dir)
    end)

    {:ok, base_dir: base_dir, workspace: workspace}
  end

  test "legacy root skills/sessions/tools are merged into workspace and removed", %{
    base_dir: base_dir,
    workspace: workspace
  } do
    :ok = Onboarding.ensure_initialized()

    refute File.exists?(Path.join(base_dir, "skills"))
    refute File.exists?(Path.join(base_dir, "sessions"))
    refute File.exists?(Path.join(base_dir, "tools"))
    refute File.exists?(Path.join(base_dir, "cron"))

    assert File.exists?(Path.join(workspace, "skills/existing-skill/SKILL.md"))
    assert File.exists?(Path.join(workspace, "sessions/existing-session/messages.jsonl"))
    assert File.exists?(Path.join(workspace, "tools/existing-tool/tool.ex"))

    assert File.exists?(Path.join(workspace, "skills/legacy-skill/SKILL.md"))
    assert File.exists?(Path.join(workspace, "sessions/legacy-session/messages.jsonl"))
    assert File.exists?(Path.join(workspace, "tools/legacy-tool/tool.ex"))

    cron_jobs =
      workspace
      |> Path.join("tasks/cron_jobs.json")
      |> File.read!()
      |> Jason.decode!()

    assert Enum.any?(cron_jobs, &(&1["name"] == "legacy-daily-summary"))
    assert Enum.any?(cron_jobs, &(&1["name"] == "current-weekly-summary"))

    memory_template = File.read!(Path.join(workspace, "memory/MEMORY.md"))
    assert memory_template =~ "## Environment Facts"
    assert memory_template =~ "## Project Conventions"
    assert memory_template =~ "## Workflow Lessons"
    refute memory_template =~ "## User Information"
  end

  test "new workspace templates do not encode identity replacement", %{workspace: workspace} do
    :ok = Onboarding.ensure_initialized()

    soul_content = File.read!(Path.join(workspace, "SOUL.md"))

    refute soul_content =~ "I am Nex Agent"
    refute soul_content =~ "I am"
    refute soul_content =~ "personal AI assistant"

    assert soul_content =~ "Persona, values, and long-term operating principles"
    assert soul_content =~ "## Personality"
    assert soul_content =~ "## Values"
    assert soul_content =~ "## Communication Style"
  end

  test "new workspace templates align with runtime contract", %{workspace: workspace} do
    :ok = Onboarding.ensure_initialized()

    agents_content = File.read!(Path.join(workspace, "AGENTS.md"))
    soul_content = File.read!(Path.join(workspace, "SOUL.md"))
    user_content = File.read!(Path.join(workspace, "USER.md"))
    tools_content = File.read!(Path.join(workspace, "TOOLS.md"))

    refute agents_content =~ "## Identity"
    refute agents_content =~ "You are **Nex Agent**"

    assert agents_content =~ "Six-Layer Evolution"
    assert agents_content =~ "SOUL: values, personality"

    refute soul_content =~ "all capabilities are skills"
    refute soul_content =~ "capabilities"

    assert user_content =~ "User Profile"
    assert user_content =~ "## Collaboration Preferences"
    refute user_content =~ "Special Instructions"

    assert tools_content =~ "Tool reference"
    assert tools_content =~ "Built-in Tool Families"
  end

  test "existing customized user files are preserved during initialization", %{
    workspace: workspace
  } do
    custom_soul = """
    # My Custom Soul

    This is my personalized SOUL content.
    I prefer a very formal tone.
    """

    custom_user = """
    # My Profile

    **Name**: Alex
    **Role**: Senior Engineer
    """

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "SOUL.md"), custom_soul)
    File.write!(Path.join(workspace, "USER.md"), custom_user)

    :ok = Onboarding.ensure_initialized()

    assert File.read!(Path.join(workspace, "SOUL.md")) == custom_soul
    assert File.read!(Path.join(workspace, "USER.md")) == custom_user
  end

  test "managed templates merge with existing content without overwriting customizations", %{
    workspace: workspace
  } do
    existing_agents = """
    # AGENTS

    My custom section above the managed block.

    <!-- BEGIN NEX:AGENTS_MANAGED_V1 -->
    Old managed content
    <!-- END NEX:AGENTS_MANAGED_V1 -->

    My custom section below the managed block.
    """

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "AGENTS.md"), existing_agents)

    :ok = Onboarding.ensure_initialized()

    result = File.read!(Path.join(workspace, "AGENTS.md"))
    assert result =~ "My custom section above the managed block"
    assert result =~ "My custom section below the managed block"
    refute result =~ "Old managed content"
    assert result =~ "<!-- BEGIN NEX:AGENTS_MANAGED_V1 -->"
    assert result =~ "<!-- END NEX:AGENTS_MANAGED_V1 -->"
    assert result =~ "System-level instructions"
  end

  test "forward-created workspaces receive aligned templates", %{workspace: workspace} do
    :ok = Onboarding.ensure_initialized()

    assert File.exists?(Path.join(workspace, "AGENTS.md"))
    assert File.exists?(Path.join(workspace, "SOUL.md"))
    assert File.exists?(Path.join(workspace, "USER.md"))
    assert File.exists?(Path.join(workspace, "TOOLS.md"))
    assert File.exists?(Path.join(workspace, "memory/MEMORY.md"))
    assert File.exists?(Path.join(workspace, "memory/HISTORY.md"))

    agents = File.read!(Path.join(workspace, "AGENTS.md"))
    soul = File.read!(Path.join(workspace, "SOUL.md"))

    refute agents =~ "Identity"
    refute soul =~ "I am Nex Agent"
  end
end
