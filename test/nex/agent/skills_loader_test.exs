defmodule Nex.Agent.SkillsLoaderTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Skills.Loader

  test "parses literal block scalar descriptions" do
    dir = temp_dir("skills-loader-literal")
    skill_dir = Path.join(dir, "daily-pollen")

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: daily-pollen
      description: |
        第一行
        第二行
      ---

      # Daily Pollen
      """
    )

    [skill] = Loader.load_from_dir(dir, filter_unavailable: false)
    assert skill.name == "daily-pollen"
    assert skill.description == "第一行\n第二行"
  end

  test "parses folded block scalar descriptions" do
    dir = temp_dir("skills-loader-folded")
    skill_dir = Path.join(dir, "daily-hunt")

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: daily-hunt
      description: >
        第一行
        第二行

        第三段
      ---

      # Daily Hunt
      """
    )

    [skill] = Loader.load_from_dir(dir, filter_unavailable: false)
    assert skill.name == "daily-hunt"
    assert skill.description == "第一行 第二行\n\n第三段"
  end

  test "loads repo-owned policy skills from .nex/skills alongside workspace skills" do
    repo_root = temp_dir("skills-loader-project")
    workspace = Path.join(repo_root, "workspace")
    repo_skill_dir = Path.join(repo_root, ".nex/skills/repo-policy")

    on_exit(fn ->
      File.rm_rf!(repo_root)
    end)

    File.mkdir_p!(Path.join(workspace, "skills"))
    File.mkdir_p!(repo_skill_dir)

    File.write!(
      Path.join(repo_skill_dir, "SKILL.md"),
      """
      ---
      name: repo-policy
      description: Repository-local workflow policy
      ---

      # Repo Policy
      """
    )

    skills =
      Loader.load_all(
        workspace: workspace,
        project_root: repo_root,
        filter_unavailable: false
      )

    assert Enum.any?(skills, &(&1.name == "repo-policy"))
  end

  defp temp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
