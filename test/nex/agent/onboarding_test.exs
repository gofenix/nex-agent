defmodule Nex.Agent.OnboardingTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Onboarding

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "nex_agent_test_#{:rand.uniform(1_000_000)}")
    base_dir = Path.join(tmp_dir, ".nex/agent")

    Application.put_env(:nex_agent, :agent_base_dir, base_dir)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :agent_base_dir)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir, base_dir: base_dir}}
  end

  describe "ensure_initialized/0" do
    test "creates directories on first run", %{base_dir: base_dir} do
      :ok = Onboarding.ensure_initialized()

      assert File.exists?(Path.join(base_dir, ".initialized"))
      assert File.exists?(Path.join(base_dir, "skills"))
      assert File.exists?(Path.join(base_dir, "sessions"))
      assert File.exists?(Path.join(base_dir, "evolution"))
    end

    test "creates default skills on first run", %{base_dir: base_dir} do
      :ok = Onboarding.ensure_initialized()

      skills_dir = Path.join(base_dir, "skills")

      expected_skills = [
        "explain-code",
        "git-commit",
        "project-analyze",
        "test-runner",
        "refactor-suggest",
        "todo"
      ]

      for skill_name <- expected_skills do
        skill_path = Path.join(skills_dir, skill_name)
        assert File.exists?(skill_path), "Expected skill directory: #{skill_path}"

        assert File.exists?(Path.join(skill_path, "SKILL.md")),
               "Expected SKILL.md in #{skill_name}"
      end
    end

    test "does not overwrite existing skills", %{base_dir: base_dir} do
      skill_dir = Path.join(base_dir, "skills/explain-code")
      File.mkdir_p!(skill_dir)

      custom_content =
        "---\nname: explain-code\ndescription: Custom description\n---\n\nCustom content"

      File.write!(Path.join(skill_dir, "SKILL.md"), custom_content)

      :ok = Onboarding.ensure_initialized()

      content = File.read!(Path.join(skill_dir, "SKILL.md"))
      assert content == custom_content
    end

    test "does not reinitialize if already initialized", %{base_dir: base_dir} do
      :ok = Onboarding.ensure_initialized()
      init_file = Path.join(base_dir, ".initialized")
      first_content = File.read!(init_file)

      :ok = Onboarding.ensure_initialized()

      second_content = File.read!(init_file)
      assert first_content == second_content
    end
  end

  describe "initialized?/0" do
    test "returns false when not initialized", _context do
      refute Onboarding.initialized?()
    end

    test "returns true when initialized", _context do
      :ok = Onboarding.ensure_initialized()
      assert Onboarding.initialized?()
    end
  end

  describe "default_skills/0" do
    test "returns list of default skills" do
      skills = Onboarding.default_skills()

      assert is_list(skills)
      assert {"explain-code", :markdown} in skills
      assert {"git-commit", :script} in skills
      assert {"todo", :elixir} in skills
    end
  end

  describe "reinitialize/0" do
    test "recreates initialization marker", %{base_dir: base_dir} do
      :ok = Onboarding.ensure_initialized()
      init_file = Path.join(base_dir, ".initialized")
      first_content = File.read!(init_file)

      :ok = Onboarding.reinitialize()

      second_content = File.read!(init_file)
      refute first_content == second_content
    end
  end
end
