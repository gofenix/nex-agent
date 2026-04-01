defmodule Nex.Agent.InboundWorkerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, InboundWorker, Memory, MemoryUpdater, Runner, Session, SessionManager, Skills}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-inbound-#{System.unique_integer([:positive])}")

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

    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Nex.Agent.Tool.Registry) == nil do
      start_supervised!({Nex.Agent.Tool.Registry, name: Nex.Agent.Tool.Registry})
    end

    if Process.whereis(Nex.Agent.SessionManager) == nil do
      start_supervised!({Nex.Agent.SessionManager, name: Nex.Agent.SessionManager})
    end

    if Process.whereis(Nex.Agent.MemoryUpdater) == nil do
      start_supervised!({Nex.Agent.MemoryUpdater, name: Nex.Agent.MemoryUpdater})
    end

    worker_name = String.to_atom("inbound_worker_test_#{System.unique_integer([:positive])}")
    parent = self()

    prompt_fun = fn agent, prompt, opts ->
      Process.put(:llm_call_count, 0)

      llm_client = fn _messages, _llm_opts ->
        case Process.get(:llm_call_count, 0) do
          0 ->
            Process.put(:llm_call_count, 1)

            {:ok,
             %{
               content: [%{"nested" => [%{"x" => 1}]}],
               finish_reason: nil,
               tool_calls: [
                 %{
                   id: "call_progress_content",
                   function: %{
                     name: "list_dir",
                     arguments: %{"path" => "."}
                   }
                 }
               ]
             }}

          _ ->
            send(parent, :llm_finished)
            {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
        end
      end

      runner_opts = [
        llm_client: llm_client,
        workspace: workspace,
        skip_consolidation: true,
        on_progress: Keyword.get(opts, :on_progress),
        channel: Keyword.get(opts, :channel),
        chat_id: Keyword.get(opts, :chat_id)
      ]

      case Runner.run(agent.session, prompt, runner_opts) do
        {:ok, result, session} -> {:ok, result, %{agent | session: session}}
        {:error, reason, session} -> {:error, reason, %{agent | session: session}}
      end
    end

    start_supervised!(%{
      id: worker_name,
      start: {InboundWorker, :start_link, [[name: worker_name, agent_prompt_fun: prompt_fun]]}
    })

    Bus.subscribe(:feishu_outbound)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      Bus.unsubscribe(:feishu_outbound)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, worker_name: worker_name}
  end

  test "feishu outbound only sends final user reply, not progress chatter", %{
    worker_name: worker_name
  } do
    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{channel: "feishu", chat_id: "chat-1", content: "hello"}
    })

    assert_receive :llm_finished, 1_000

    payloads = collect_feishu_payloads([])

    assert Enum.any?(payloads, &(&1.content == "done"))
    refute Enum.any?(payloads, &(&1.metadata["_progress"] == true))

    refute Enum.any?(payloads, fn payload ->
             is_binary(payload.content) and
               String.contains?(
                 payload.content,
                 "nofunction clause matching in io.chardata_to_string"
               )
           end)
  end

  test "inbound worker forwards media from payload metadata into agent prompt opts", %{} do
    parent = self()
    worker_name = String.to_atom("inbound_worker_media_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, prompt, opts ->
      send(parent, {:prompt_opts, prompt, Keyword.get(opts, :media)})
      {:ok, "done", agent}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{
        channel: "feishu",
        chat_id: "chat-1",
        content: "看图",
        metadata: %{
          "media" => [
            %{
              "type" => "image",
              "url" => "data:image/png;base64,iVBORw0KGgo=",
              "mime_type" => "image/png"
            }
          ]
        }
      }
    })

    assert_receive {:prompt_opts, "看图", media}, 1_000

    assert media == [
             %{
               "type" => "image",
               "url" => "data:image/png;base64,iVBORw0KGgo=",
               "mime_type" => "image/png"
             }
           ]
  end

  test "feishu reply via message tool does not append duplicate narration", %{
    workspace: workspace
  } do
    parent = self()
    worker_name = String.to_atom("inbound_worker_message_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, prompt, opts ->
      Process.put(:llm_call_count, 0)

      llm_client = fn _messages, _llm_opts ->
        case Process.get(:llm_call_count, 0) do
          0 ->
            Process.put(:llm_call_count, 1)

            {:ok,
             %{
               content: "用户是在打个招呼。我直接回复一下。",
               finish_reason: nil,
               tool_calls: [
                 %{
                   id: "call_message_reply",
                   function: %{
                     name: "message",
                     arguments: %{"content" => "收到 123 👋"}
                   }
                 }
               ]
             }}

          _ ->
            send(parent, :message_tool_turn_finished)
            {:ok, %{content: "已发送一个简单的表情回复。", finish_reason: nil, tool_calls: []}}
        end
      end

      runner_opts = [
        llm_client: llm_client,
        workspace: workspace,
        skip_consolidation: true,
        on_progress: Keyword.get(opts, :on_progress),
        channel: Keyword.get(opts, :channel),
        chat_id: Keyword.get(opts, :chat_id)
      ]

      case Runner.run(agent.session, prompt, runner_opts) do
        {:ok, result, session} -> {:ok, result, %{agent | session: session}}
        {:error, reason, session} -> {:error, reason, %{agent | session: session}}
      end
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{channel: "feishu", chat_id: "chat-1", content: "123"}
    })

    assert_receive :message_tool_turn_finished, 1_000

    payloads = collect_feishu_payloads([])

    assert Enum.any?(payloads, fn payload ->
             payload.content == "收到 123 👋" and payload.metadata["_from_tool"] == true
           end)

    refute Enum.any?(payloads, &(&1.content == "已发送一个简单的表情回复。"))
    refute Enum.any?(payloads, &(&1.metadata["_progress"] == true))
  end

  test "inbound worker publishes final reply before background memory refresh finishes", %{
    workspace: workspace
  } do
    parent = self()
    worker_name = String.to_atom("inbound_worker_memory_#{System.unique_integer([:positive])}")

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

  defp collect_feishu_payloads(acc) do
    receive do
      {:bus_message, :feishu_outbound, payload} ->
        collect_feishu_payloads([payload | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp wait_for(predicate, attempts \\ 50)

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
