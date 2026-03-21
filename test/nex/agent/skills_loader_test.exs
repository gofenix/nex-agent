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

  defp temp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
