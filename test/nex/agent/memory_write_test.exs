defmodule Nex.Agent.MemoryWriteTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Memory
  alias Nex.Agent.Tool.MemoryWrite

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-memory-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Long-term Memory\n")
    File.write!(Path.join(workspace, "USER.md"), "# User Profile\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "memory_write writes MEMORY.md for target=memory", %{workspace: workspace} do
    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "add",
                 "target" => "memory",
                 "content" => "Project uses OTP supervision."
               },
               %{workspace: workspace}
             )

    assert Memory.read_long_term(workspace: workspace) =~ "Project uses OTP supervision."
  end

  test "memory_write writes USER.md for target=user", %{workspace: workspace} do
    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "add",
                 "target" => "user",
                 "content" => "Prefers concise Chinese responses."
               },
               %{workspace: workspace}
             )

    assert Memory.read_user_profile(workspace: workspace) =~ "Prefers concise Chinese responses."
  end

  test "replace and remove are stable", %{workspace: workspace} do
    :ok =
      Memory.write_user_profile("Name: fenix\nTimezone: Asia/Shanghai\n", workspace: workspace)

    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "replace",
                 "target" => "user",
                 "old_text" => "Asia/Shanghai",
                 "content" => "UTC+8"
               },
               %{workspace: workspace}
             )

    assert Memory.read_user_profile(workspace: workspace) =~ "UTC+8"

    assert {:ok, _} =
             MemoryWrite.execute(
               %{"action" => "remove", "target" => "user", "old_text" => "Name: fenix"},
               %{workspace: workspace}
             )

    refute Memory.read_user_profile(workspace: workspace) =~ "Name: fenix"
  end
end
