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

    File.mkdir_p!(Path.join(workspace, "skills/existing-skill"))
    File.mkdir_p!(Path.join(workspace, "sessions/existing-session"))
    File.mkdir_p!(Path.join(workspace, "tools/existing-tool"))

    File.write!(Path.join(workspace, "skills/existing-skill/SKILL.md"), "existing skill\n")
    File.write!(Path.join(workspace, "sessions/existing-session/messages.jsonl"), "{}\n")

    File.write!(
      Path.join(workspace, "tools/existing-tool/tool.ex"),
      "defmodule ExistingTool do\nend\n"
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

    assert File.exists?(Path.join(workspace, "skills/existing-skill/SKILL.md"))
    assert File.exists?(Path.join(workspace, "sessions/existing-session/messages.jsonl"))
    assert File.exists?(Path.join(workspace, "tools/existing-tool/tool.ex"))

    assert File.exists?(Path.join(workspace, "skills/legacy-skill/SKILL.md"))
    assert File.exists?(Path.join(workspace, "sessions/legacy-session/messages.jsonl"))
    assert File.exists?(Path.join(workspace, "tools/legacy-tool/tool.ex"))
  end
end
