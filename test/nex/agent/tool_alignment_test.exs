defmodule Nex.Agent.ToolAlignmentTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.{SoulUpdate, ToolList}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-alignment-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    Application.put_env(:nex_agent, :workspace_path, workspace)

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Nex.Agent.Tool.Registry) == nil do
      start_supervised!({Nex.Agent.Tool.Registry, name: Nex.Agent.Tool.Registry})
    end

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "soul_update writes SOUL.md in configured workspace", %{workspace: workspace} do
    assert {:ok, _} = SoulUpdate.execute(%{"content" => "# Soul\nStay precise.\n"}, %{})
    assert File.read!(Path.join(workspace, "SOUL.md")) =~ "Stay precise."
  end

  test "tool_list exposes code layer for reflect and upgrade_code" do
    assert {:ok, result} = ToolList.execute(%{"scope" => "builtin"}, %{})

    builtins = result[:builtin]
    reflect = Enum.find(builtins, &(&1["name"] == "reflect"))
    upgrade = Enum.find(builtins, &(&1["name"] == "upgrade_code"))
    tool_create = Enum.find(builtins, &(&1["name"] == "tool_create"))

    assert reflect["layer"] == "code"
    assert upgrade["layer"] == "code"
    assert tool_create["layer"] == "tool"
  end
end
