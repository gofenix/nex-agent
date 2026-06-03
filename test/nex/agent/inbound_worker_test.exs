defmodule Nex.Agent.InboundWorkerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, InboundWorker, Memory, Runner, Session, Skills}

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
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace, worker_name: worker_name}
  end

  test "feishu outbound only sends final user reply, not progress chatter", %{
    worker_name: worker_name
  } do
    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{
        channel: "feishu",
        chat_id: "chat-1",
        content: "hello",
        metadata: %{"_from_subagent" => true}
      }
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
          "_from_subagent" => true,
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

  test "feishu task metadata with atom keys forces task executor options" do
    parent = self()

    worker_name =
      String.to_atom("inbound_worker_feishu_task_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, prompt, opts ->
      send(parent, {:prompt_opts, prompt, opts})
      {:ok, "done", agent}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{
        channel: "feishu",
        chat_id: "ou_user",
        content: "/rerun_feishu_task task_1",
        metadata: %{
          _from_feishu_task: true,
          task_id: "task_1",
          task_action: "rerun"
        }
      }
    })

    assert_receive {:prompt_opts, prompt, opts}, 1_000
    assert prompt =~ "/rerun_feishu_task task_1"
    assert prompt =~ "\"task_id\": \"task_1\""
    assert prompt =~ "Do not use the internal Nex personal task tool"
    assert Keyword.get(opts, :force_skills) == ["feishu-task-executor"]
    assert Keyword.get(opts, :history_limit) == 0
    assert Keyword.get(opts, :skip_consolidation) == true

    refute_receive {:bus_message, :feishu_outbound, _}, 100
  end

  test "github metadata forces issue executor options without preclassified action" do
    parent = self()

    worker_name = String.to_atom("inbound_worker_github_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, prompt, opts ->
      send(parent, {:prompt_opts, prompt, opts})
      {:ok, "done", agent}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{
        channel: "github",
        chat_id: "gofenix/nex-agent#12",
        content: "@nex 这个 case 还不对，空输入应该直接报错",
        metadata: %{
          _from_github: true,
          event_type: "issue_comment",
          issue_url: "https://github.com/gofenix/nex-agent/issues/12",
          issue_number: 12,
          issue_title: "add jp readme",
          issue_body: "add jp",
          repo: "gofenix/nex-agent",
          work_dir: "/Users/fenix/.nex/agent/workspace/github/items/PVTI_123/gofenix__nex-agent",
          branch: "codex/github-issue-12-PVTI_123",
          pr_url: "https://github.com/gofenix/nex-agent/pull/13",
          comment_body: "@nex 这个 case 还不对，空输入应该直接报错"
        }
      }
    })

    assert_receive {:prompt_opts, prompt, opts}, 1_000
    assert prompt =~ "@nex 这个 case 还不对，空输入应该直接报错"
    assert prompt =~ "\"_from_github\": true"
    assert prompt =~ "\"work_dir\""
    assert prompt =~ "\"branch\": \"codex/github-issue-12-PVTI_123\""
    assert prompt =~ "\"pr_url\": \"https://github.com/gofenix/nex-agent/pull/13\""
    assert prompt =~ "Follow the github-issue-executor skill exactly"

    assert prompt =~
             "Decide from the GitHub context whether to start, continue, retry, stop, report status, or ask a clarifying question."

    refute prompt =~ "\"action\""
    assert prompt =~ "opencode_run"
    assert prompt =~ "Do not call opencode through the bash tool"
    assert prompt =~ "stdout/stderr log"
    assert prompt =~ "Do not run opencode in a long-lived checkout"
    assert prompt =~ "timeout: 1800"
    assert Keyword.get(opts, :force_skills) == ["github-issue-executor"]
    assert Keyword.get(opts, :history_limit) == 0
    assert Keyword.get(opts, :skip_consolidation) == true
    assert Keyword.get(opts, :max_iterations) == 20
    assert Keyword.get(opts, :timeout) == 1_800

    refute_receive {:bus_message, :github_outbound, _}, 100
  end

  test "github project metadata forces opencode_run as the first iteration tool" do
    parent = self()

    worker_name =
      String.to_atom("inbound_worker_github_project_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, prompt, opts ->
      send(parent, {:prompt_opts, prompt, opts})
      {:ok, "done", agent}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{
        channel: "github",
        chat_id: "gofenix",
        content: "Pick up Issue #12: add jp readme",
        metadata: %{
          _from_github_project: true,
          issue_number: 12,
          issue_title: "add jp readme",
          issue_body: "add jp",
          repo: "gofenix/nex-agent",
          work_dir: "/Users/fenix/.nex/agent/workspace/github/items/PVTI_123/gofenix__nex-agent",
          branch: "codex/github-issue-12-PVTI_123",
          opencode_model: "opencode/test-model"
        }
      }
    })

    assert_receive {:prompt_opts, prompt, opts}, 1_000
    assert prompt =~ "\"_from_github_project\": true"
    assert prompt =~ "Follow the github-issue-executor skill exactly"
    assert Keyword.get(opts, :force_skills) == ["github-issue-executor"]
    assert Keyword.get(opts, :first_iteration_tool_only) == ["opencode_run"]
    assert Keyword.get(opts, :first_iteration_tool_choice) == "opencode_run"
    assert Keyword.get(opts, :timeout) == 1_800
  end

  test "coding task watchdog timeout is longer than the opencode tool timeout" do
    assert InboundWorker.task_watchdog_timeout_ms(%{
             metadata: %{"_from_github" => true}
           }) == 1_805_000

    assert InboundWorker.task_watchdog_timeout_ms(%{
             metadata: %{"_from_feishu_task" => true}
           }) == 1_805_000

    assert InboundWorker.task_watchdog_timeout_ms(%{
             metadata: %{"_from_github_project" => true}
           }) == 1_805_000

    assert InboundWorker.task_watchdog_timeout_ms(%{metadata: %{}}) == 600_000
  end

  test "timeout check handles tuple runtime keys without crashing" do
    worker_name = String.to_atom("inbound_worker_timeout_#{System.unique_integer([:positive])}")
    start_supervised!({InboundWorker, name: worker_name})

    task_pid =
      spawn(fn ->
        Process.sleep(:infinity)
      end)

    key = {"/tmp/workspace", "github:gofenix"}

    worker_pid = Process.whereis(worker_name)

    :sys.replace_state(worker_pid, fn state ->
      %{state | active_tasks: Map.put(state.active_tasks, key, task_pid)}
    end)

    ref = Process.monitor(task_pid)
    send(worker_pid, {:check_timeout, key, task_pid})

    assert_receive {:DOWN, ^ref, :process, ^task_pid, :killed}, 1_000
    assert Process.alive?(worker_pid)
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
      %{
        channel: "feishu",
        chat_id: "chat-1",
        content: "123",
        metadata: %{"_from_subagent" => true}
      }
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
              "memory_refresh_llm_call_fun" => fn _messages, _llm_opts ->
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

  test "feishu inbound uses processing reactions without creating a thinking card" do
    parent = self()

    start_feishu_for_reaction_test(parent)

    worker_name = String.to_atom("inbound_worker_reaction_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, _prompt, opts ->
      send(parent, {:prompt_opts, Keyword.get(opts, :on_progress)})
      {:ok, "done", agent}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{
        channel: "feishu",
        chat_id: "oc_chat",
        content: "hello",
        message_id: "om_inbound",
        metadata: %{
          "_from_subagent" => true,
          "message_id" => "om_inbound",
          "chat_type" => "group"
        }
      }
    })

    assert_receive {:prompt_opts, nil}, 1_000

    assert_receive {:feishu_http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:feishu_http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages/om_inbound/reactions"
    assert body2 == %{"reaction_type" => %{"emoji_type" => "Typing"}}

    assert_receive {:feishu_http_delete, url3, _headers3}
    assert url3 =~ "/im/v1/messages/om_inbound/reactions/re_typing"

    payloads = collect_feishu_payloads([])
    assert Enum.any?(payloads, &(&1.content == "done"))

    refute Enum.any?(
             payloads,
             &(is_binary(&1.content) and String.contains?(&1.content, "Thinking"))
           )
  end

  test "feishu inbound marks failed turns with failure reaction" do
    parent = self()

    start_feishu_for_reaction_test(parent)

    worker_name = String.to_atom("inbound_worker_failure_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, _prompt, _opts ->
      {:error, :boom, agent}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %{
        channel: "feishu",
        chat_id: "oc_chat",
        content: "hello",
        message_id: "om_failed",
        metadata: %{
          "_from_subagent" => true,
          "message_id" => "om_failed",
          "chat_type" => "group"
        }
      }
    })

    assert_receive {:feishu_http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:feishu_http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages/om_failed/reactions"
    assert body2 == %{"reaction_type" => %{"emoji_type" => "Typing"}}

    assert_receive {:feishu_http_delete, url3, _headers3}
    assert url3 =~ "/im/v1/messages/om_failed/reactions/re_typing"

    assert_receive {:feishu_http_post, url4, body4, _headers4}
    assert url4 =~ "/im/v1/messages/om_failed/reactions"
    assert body4 == %{"reaction_type" => %{"emoji_type" => "CrossMark"}}

    payloads = collect_feishu_payloads([])

    assert Enum.any?(
             payloads,
             &(is_binary(&1.content) and String.contains?(&1.content, "Error:"))
           )
  end

  defp collect_feishu_payloads(acc) do
    receive do
      {:bus_message, :feishu_outbound, payload} ->
        collect_feishu_payloads([payload | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp start_feishu_for_reaction_test(parent) do
    http_post_fun = fn url, body, headers ->
      send(parent, {:feishu_http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/reactions") ->
          {:ok, %{"code" => 0, "data" => %{"reaction_id" => "re_typing"}}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_reply"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_delete_fun = fn url, headers ->
      send(parent, {:feishu_http_delete, url, headers})
      {:ok, %{"code" => 0}}
    end

    config = %Nex.Agent.Config{Nex.Agent.Config.default() | feishu: %{"enabled" => false}}

    pid =
      start_supervised!(
        {Nex.Agent.Channel.Feishu,
         name: Nex.Agent.Channel.Feishu,
         config: config,
         http_post_fun: http_post_fun,
         http_post_multipart_fun: fn _url, _body, _headers -> {:error, :unexpected} end,
         http_get_fun: fn _url, _headers -> {:error, :unexpected} end,
         http_delete_fun: http_delete_fun}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    pid
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
