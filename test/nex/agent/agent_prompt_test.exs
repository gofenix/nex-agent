defmodule Nex.AgentPromptTest do
  use ExUnit.Case, async: false

  alias Nex.Agent
  alias Nex.Agent.Session

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-prompt-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "prompt forwards forced skills into runner context", %{workspace: workspace} do
    parent = self()

    llm_client = fn messages, _opts ->
      send(parent, {:messages, messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    agent = %Agent{
      session_key: "feishu:ou_user",
      session: Session.new("feishu:ou_user"),
      provider: :anthropic,
      model: "test-model",
      api_key: "test-key",
      workspace: workspace,
      cwd: workspace,
      max_iterations: 1
    }

    assert {:ok, "ok", _agent} =
             Agent.prompt(agent, "dispatch feishu task",
               llm_client: llm_client,
               workspace: workspace,
               skip_consolidation: true,
               force_skills: ["feishu-task-executor"]
             )

    assert_receive {:messages, messages}, 1_000
    system = Enum.find(messages, &(&1["role"] == "system"))["content"]

    assert system =~ "# Feishu Task Executor"
    assert system =~ "lark-cli task tasks get"
    assert system =~ "opencode run"
    assert system =~ "Do not use the internal `task` tool"
  end
end
