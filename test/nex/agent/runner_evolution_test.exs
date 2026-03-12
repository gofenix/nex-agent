defmodule Nex.Agent.RunnerEvolutionTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runner, Session, Skills}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-runner-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "# History\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

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

  test "memory nudge appears after enough turns and resets after memory_write", %{
    workspace: workspace
  } do
    agent_messages = self()

    llm_client = fn messages, _opts ->
      send(agent_messages, {:messages, messages})

      if Enum.any?(
           messages,
           &(&1["role"] == "system" and String.contains?(&1["content"], "memory_write"))
         ) do
        %{
          content: "",
          finish_reason: nil,
          tool_calls: [
            %{
              id: "call_mem",
              function: %{
                name: "memory_write",
                arguments: %{
                  "action" => "add",
                  "target" => "memory",
                  "content" => "Project uses runtime nudges."
                }
              }
            }
          ]
        }
      else
        %{content: "ok", finish_reason: nil, tool_calls: []}
      end
      |> then(&{:ok, &1})
    end

    session =
      Session.new("memory-nudge")
      |> Map.put(:metadata, %{"runtime_evolution" => %{"turns_since_memory_write" => 5}})

    {:ok, _result, session} =
      Runner.run(session, "记住这个项目约定",
        llm_client: llm_client,
        workspace: workspace,
        skip_consolidation: true
      )

    assert_receive {:messages, messages}

    assert Enum.any?(
             messages,
             &(&1["role"] == "system" and
                 String.contains?(&1["content"], "Several exchanges have passed"))
           )

    assert get_in(session.metadata, ["runtime_evolution", "turns_since_memory_write"]) == 0
  end

  test "complex task sets next-turn skill nudge and skill creation clears it", %{
    workspace: workspace
  } do
    llm_client_first = fn _messages, _opts ->
      {:ok,
       %{
         content: "",
         finish_reason: nil,
         tool_calls: [
           %{id: "a", function: %{name: "list_dir", arguments: %{"path" => "."}}},
           %{id: "b", function: %{name: "read", arguments: %{"path" => "README.md"}}},
           %{id: "c", function: %{name: "read", arguments: %{"path" => "mix.exs"}}},
           %{id: "d", function: %{name: "skill_list", arguments: %{}}}
         ]
       }}
    end

    {:ok, _result, session_after_first} =
      Runner.run(Session.new("skill-nudge"), "先分析一下项目",
        llm_client: llm_client_first,
        workspace: workspace,
        skip_consolidation: true
      )

    assert get_in(session_after_first.metadata, ["runtime_evolution", "pending_skill_nudge"]) ==
             true

    parent = self()

    llm_client_second = fn messages, _opts ->
      send(parent, {:messages, messages})

      {:ok,
       %{
         content: "",
         finish_reason: nil,
         tool_calls: [
           %{
             id: "skill_create",
             function: %{
               name: "skill_create",
               arguments: %{
                 "name" => "project-inspection",
                 "description" => "Inspect a project before changes",
                 "content" => "Read README, inspect mix.exs, then list important files."
               }
             }
           }
         ]
       }}
    end

    {:ok, _result, session_after_second} =
      Runner.run(session_after_first, "把刚才的方法沉淀一下",
        llm_client: llm_client_second,
        workspace: workspace,
        skip_consolidation: true
      )

    assert_receive {:messages, messages}

    assert Enum.any?(
             messages,
             &(&1["role"] == "system" and
                 String.contains?(&1["content"], "previous task was complex"))
           )

    assert get_in(session_after_second.metadata, ["runtime_evolution", "pending_skill_nudge"]) ==
             false
  end
end
