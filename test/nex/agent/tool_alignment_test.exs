defmodule Nex.Agent.TestSkillMessageTool do
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "skill_message"
  def description, do: "Test tool that collides with skill-generated name."
  def category, do: :base

  def definition do
    %{
      name: "skill_message",
      description: description(),
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    }
  end

  def execute(_args, _ctx), do: {:ok, "ok"}
end

defmodule Nex.Agent.ToolAlignmentTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runner, Session, Skills}
  alias Nex.Agent.Tool.{Registry, SoulUpdate, ToolList}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-alignment-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    Application.put_env(:nex_agent, :workspace_path, workspace)

    Skills.load()

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Registry) == nil do
      start_supervised!({Registry, name: Registry})
    end

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      Registry.unregister("skill_message")

      if Process.whereis(Skills) do
        Agent.update(Skills, &Map.delete(&1, "message"))
      end

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "soul_update writes SOUL.md in configured workspace", %{workspace: workspace} do
    assert {:ok, _} = SoulUpdate.execute(%{"content" => "# Soul\nStay precise.\n"}, %{})
    assert File.read!(Path.join(workspace, "SOUL.md")) =~ "Stay precise."
  end

  test "tool_list exposes evolution layers without merging user and memory" do
    assert {:ok, result} = ToolList.execute(%{"scope" => "builtin"}, %{})

    builtins = result[:builtin]
    memory_write = Enum.find(builtins, &(&1["name"] == "memory_write"))
    reflect = Enum.find(builtins, &(&1["name"] == "reflect"))
    upgrade = Enum.find(builtins, &(&1["name"] == "upgrade_code"))
    tool_create = Enum.find(builtins, &(&1["name"] == "tool_create"))

    assert memory_write["layers"] == ["user", "memory"]
    assert reflect["layers"] == ["code"]
    assert upgrade["layers"] == ["code"]
    assert tool_create["layers"] == ["tool"]
  end

  test "duplicate tool name is submitted once with registry precedence", %{workspace: workspace} do
    Agent.update(Skills, fn skills ->
      Map.put(skills, "message", %{
        name: "message",
        description: "Creates a colliding skill tool name.",
        parameters: %{},
        user_invocable: true,
        content: "Return the input unchanged."
      })
    end)

    Registry.register(Nex.Agent.TestSkillMessageTool)
    wait_for_registry_tool("skill_message", Nex.Agent.TestSkillMessageTool)

    parent = self()

    llm_client = fn _messages, opts ->
      send(parent, {:tools, Keyword.get(opts, :tools, [])})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", _session} =
             Runner.run(Session.new("tool-dedupe"), "show available tools",
               llm_client: llm_client,
               workspace: workspace,
               skip_consolidation: true
             )

    assert_receive {:tools, tools}

    names = Enum.map(tools, & &1["name"])

    assert Enum.count(names, fn name -> name == "skill_message" end) == 1
  end

  defp wait_for_registry_tool(name, module, attempts \\ 20)

  defp wait_for_registry_tool(_name, _module, 0),
    do: flunk("registry tool did not register in time")

  defp wait_for_registry_tool(name, module, attempts) do
    case Registry.get(name) do
      ^module ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_registry_tool(name, module, attempts - 1)
    end
  end
end
