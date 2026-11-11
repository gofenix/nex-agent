defmodule Nex.Agent.SkillsTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Skills

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-skills-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "skills"))

    if Process.whereis(Skills) == nil do
      start_supervised!({Skills, []})
    end

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "draft skills stay out of llm discovery and execution until published", %{
    workspace: workspace
  } do
    assert {:ok, draft} =
             Skills.create(
               %{
                 name: "draft_memory_probe",
                 description: "[Draft] Check stuck memory state",
                 content: "<!-- status: draft, source: evolution -->\n\nUse this draft.",
                 user_invocable: false
               },
               workspace: workspace
             )

    assert draft.draft
    refute Enum.any?(Skills.for_llm(workspace: workspace), &(&1["name"] == "draft_memory_probe"))

    assert {:error, reason} =
             Skills.execute("draft_memory_probe", %{"probe" => "now"}, workspace: workspace)

    assert reason =~ "still draft-only"

    assert {:ok, published} = Skills.publish_draft("draft_memory_probe", workspace: workspace)
    refute published.draft

    assert Enum.any?(Skills.for_llm(workspace: workspace), &(&1["name"] == "draft_memory_probe"))

    assert {:ok, %{result: "Use this draft."}} =
             Skills.execute("draft_memory_probe", %{}, workspace: workspace)
  end
end
