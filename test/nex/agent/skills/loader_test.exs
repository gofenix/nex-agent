defmodule Nex.Agent.Skills.LoaderTest do
  use ExUnit.Case
  alias Nex.Agent.Skills.Loader

  describe "load_from_dir/1" do
    test "loads skills from directory" do
      unique_id = :rand.uniform(100_000_000)
      tmp_dir = System.tmp_dir!() |> Path.join("test-skills-#{unique_id}")
      File.mkdir_p!(Path.join(tmp_dir, "test-skill"))

      skill_md = """
      ---
      name: test-skill
      description: A test skill
      allowed-tools: Read, Grep
      ---

      This is the skill content.
      """

      File.write!(Path.join([tmp_dir, "test-skill", "SKILL.md"]), skill_md)

      try do
        skills = Loader.load_from_dir(tmp_dir)

        assert length(skills) >= 1
        skill = Enum.find(skills, &(&1.name == "test-skill"))
        assert skill != nil
        assert skill.description == "A test skill"
        assert skill.allowed_tools == ["Read", "Grep"]
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "handles missing directory" do
      skills = Loader.load_from_dir("/nonexistent/path")
      assert skills == []
    end
  end
end
