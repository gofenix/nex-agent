defmodule Nex.Agent.ContextBuilderTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.ContextBuilder

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-context-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "Project conventions live here.\n")

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "system prompt includes runtime evolution guidance", %{workspace: workspace} do
    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ "## Runtime Evolution"
    assert prompt =~ "Save durable user profile details"
    assert prompt =~ "Save repeatable multi-step procedures"
  end

  test "runtime system messages are injected without becoming user content", %{
    workspace: workspace
  } do
    messages =
      ContextBuilder.build_messages([], "hello", "telegram", "1", nil,
        workspace: workspace,
        runtime_system_messages: ["[Runtime Evolution Nudge] Save durable knowledge if needed."]
      )

    assert Enum.at(messages, 1) == %{
             "role" => "system",
             "content" => "[Runtime Evolution Nudge] Save durable knowledge if needed."
           }

    assert List.last(messages)["role"] == "user"
    refute List.last(messages)["content"] =~ "[Runtime Evolution Nudge]"
  end
end
