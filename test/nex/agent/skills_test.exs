defmodule Nex.Agent.SkillsTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Skills
  alias Nex.Agent.Skills.Loader

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "nex_agent_skills_test_#{System.unique_integer([:positive])}")
    home_dir = Path.join(tmp_dir, "home")
    cwd_dir = Path.join(tmp_dir, "cwd")
    skills_dir = Path.join(home_dir, ".nex/agent/workspace/skills")

    File.mkdir_p!(skills_dir)
    File.mkdir_p!(cwd_dir)

    original_home = System.get_env("HOME")
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf!(tmp_dir)
    end)

    start_supervised!(Skills)
    %{skills_dir: skills_dir, cwd_dir: cwd_dir}
  end

  test "create rejects legacy skill types" do
    assert {:error, message} =
             Skills.create(%{name: "legacy", description: "x", type: "elixir", content: "..."})

    assert message =~ "Markdown-only"
  end

  test "create writes markdown skill and execute substitutes arguments", %{skills_dir: skills_dir} do
    assert {:ok, skill} =
             Skills.create(%{
               name: "review_code",
               description: "Review code changes",
               content: "Input: $ARGUMENTS",
               parameters: %{"path" => %{"type" => "string"}},
               allowed_tools: ["read", "bash"]
             })

    assert skill.name == "review_code"
    assert File.exists?(Path.join([skills_dir, "review_code", "SKILL.md"]))

    assert {:ok, %{result: result}} = Skills.execute("review_code", %{"path" => "lib/app.ex"})
    assert result =~ ~s("path":"lib/app.ex")
  end

  test "create safely serializes frontmatter strings with special characters", %{skills_dir: skills_dir} do
    assert {:ok, skill} =
             Skills.create(%{
               name: "quoted_skill",
               description: "Review: frontend\nline two",
               content: "Body",
               parameters: %{"note" => %{"type" => "string", "description" => "A: B"}},
               allowed_tools: ["read:only", "bash"]
             })

    skill_file = Path.join([skills_dir, "quoted_skill", "SKILL.md"])
    content = File.read!(skill_file)

    assert content =~ ~s(description: "Review: frontend\\nline two")
    assert content =~ ~s(    description: "A: B")
    assert skill.description == "Review: frontend\nline two"

    [loaded] = Loader.load_from_dir(skills_dir)
    assert loaded.description == "Review: frontend\nline two"
    assert loaded.parameters["note"]["description"] == "A: B"
    assert loaded.allowed_tools == ["read:only", "bash"]
  end

  test "loader ignores legacy companion files and keeps markdown body", %{skills_dir: skills_dir} do
    skill_dir = Path.join(skills_dir, "legacy_mix")
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: legacy_mix
    description: Legacy mixed skill
    always: true
    ---

    Use the markdown body.
    """)

    File.write!(Path.join(skill_dir, "skill.ex"), "defmodule Legacy do end")
    File.write!(Path.join(skill_dir, "script.sh"), "#!/bin/bash")
    File.write!(Path.join(skill_dir, "mcp.json"), "{}")
    File.write!(Path.join(skill_dir, "skill.json"), ~s({"type":"elixir"}))

    [skill] = Loader.load_from_dir(skills_dir)
    assert skill.type == "markdown"
    assert skill.content == "Use the markdown body."
    assert skill.always == true
  end
end
