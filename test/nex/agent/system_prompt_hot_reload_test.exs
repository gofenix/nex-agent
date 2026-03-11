defmodule Nex.Agent.SystemPromptHotReloadTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.ContextBuilder

  test "system prompt teaches OTP hot-update expectations" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "nex_agent_system_prompt_hot_reload_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    prompt = ContextBuilder.build_system_prompt(workspace: tmp_dir, skip_skills: true)

    assert prompt =~
             "Treat successful `.ex` changes as hot-updated by default. Only suggest a restart if tools or the runtime explicitly report hot reload failed."

    assert prompt =~ "Do not infer restarts from process age or uptime."

    assert prompt =~
             "Caveat: the current call may still run old code. Expect the next call to observe the new version."

    soul_template = Nex.Agent.Workspace.templates()["SOUL.md"]

    assert soul_template =~
             "Treat successful `.ex` changes as hot-updated by default. Only suggest a restart if tools or the runtime explicitly report hot reload failed."

    assert soul_template =~ "Do not infer restarts from process age or uptime."

    assert soul_template =~
             "Caveat: the current call may still run old code. Expect the next call to observe the new version."
  end
end
