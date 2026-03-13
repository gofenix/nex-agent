defmodule Nex.Agent.ProfilePathGuardTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.{Edit, Read, Write}

  setup do
    workspace = Path.join("/tmp", "nex-agent-profile-guard-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/USER.md"), "shadow")
    Application.put_env(:nex_agent, :workspace_path, workspace)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "read/write/edit block workspace/memory/USER.md", %{workspace: workspace} do
    shadow_path = Path.join(workspace, "memory/USER.md")

    assert {:error, msg} = Read.execute(%{"path" => shadow_path}, %{})
    assert msg =~ "workspace/USER.md"

    assert {:error, msg} = Write.execute(%{"path" => shadow_path, "content" => "x"}, %{})
    assert msg =~ "user_update"

    assert {:error, msg} =
             Edit.execute(%{"path" => shadow_path, "search" => "shadow", "replace" => "x"}, %{})

    assert msg =~ "user_update"
  end
end
