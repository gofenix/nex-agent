defmodule Nex.Agent.InboundWorkerMemoryRefreshTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, InboundWorker, Memory, MemoryUpdater, Session, SessionManager}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-inbound-memory-refresh-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)

    start_or_restart_supervised!({Bus, name: Bus})
    start_or_restart_supervised!({SessionManager, name: SessionManager})
    start_or_restart_supervised!({MemoryUpdater, name: MemoryUpdater})
    start_or_restart_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})

    Bus.subscribe(:feishu_outbound)

    on_exit(fn ->
      if Process.whereis(Bus), do: Bus.unsubscribe(:feishu_outbound)
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "publishes final reply before background memory refresh finishes", %{workspace: workspace} do
    parent = self()
    worker_name = String.to_atom("inbound_worker_memory_only_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, _prompt, _opts ->
      updated_session =
        agent.session
        |> Session.add_message("user", "hello")
        |> Session.add_message("assistant", "final reply")
        |> then(fn session ->
          metadata =
            Map.merge(session.metadata || %{}, %{
              "memory_refresh_llm_call_fun" =>
                fn _messages, _llm_opts ->
                  send(parent, :memory_refresh_started)
                  Process.sleep(200)

                  {:ok,
                   %{
                     "status" => "update",
                     "memory_update" =>
                       "# Long-term Memory\n\n## User Preferences\n- Likes concise replies.\n"
                   }}
                end
            })

          %{session | metadata: metadata}
        end)

      {:ok, "final reply", %{agent | session: updated_session, workspace: workspace}}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{channel: "feishu", chat_id: "chat-memory", content: "hello"}
    })

    assert_receive {:bus_message, :feishu_outbound, payload}, 1_000
    assert payload.content == "final reply"
    assert Memory.read_long_term(workspace: workspace) == "# Memory\n"

    assert_receive :memory_refresh_started, 1_000

    wait_for(fn ->
      Memory.read_long_term(workspace: workspace) =~ "Likes concise replies."
    end)
  end

  defp start_or_restart_supervised!(child_spec) do
    case start_supervised(child_spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp wait_for(predicate, attempts \\ 60)

  defp wait_for(_predicate, 0) do
    flunk("condition did not become true in time")
  end

  defp wait_for(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      wait_for(predicate, attempts - 1)
    end
  end
end
