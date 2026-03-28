defmodule Nex.Agent.Test.MalformedTool do
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "malformed_tool"
  def description, do: "Returns a bare map instead of a tagged tuple"
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    }
  end

  def execute(_args, _ctx), do: %{success: false, output: 0}
end

defmodule Nex.Agent.RunnerEvolutionTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, ContextBuilder, Onboarding, Runner, Session, Skills}

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

    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
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
                  "action" => "append",
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

    system_prompt = Enum.find(messages, &(&1["role"] == "system"))["content"]
    assert system_prompt =~ "use user_update"
    assert system_prompt =~ "use memory_write"

    assert get_in(session.metadata, ["runtime_evolution", "turns_since_memory_write"]) == 0
  end

  test "runner includes media in the user message content", %{workspace: workspace} do
    parent = self()

    llm_client = fn messages, _opts ->
      send(parent, {:messages, messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    media = [
      %{
        "type" => "image",
        "url" => "data:image/png;base64,iVBORw0KGgo=",
        "mime_type" => "image/png"
      }
    ]

    {:ok, _result, _session} =
      Runner.run(Session.new("runner-media"), "这张图里是什么",
        llm_client: llm_client,
        media: media,
        workspace: workspace,
        skip_consolidation: true,
        channel: "feishu",
        chat_id: "ou_test"
      )

    assert_receive {:messages, messages}
    user_message = List.last(messages)

    assert user_message["role"] == "user"
    assert is_list(user_message["content"])

    assert Enum.any?(user_message["content"], fn
             %{
               "type" => "image",
               "source" => %{
                 "url" => "data:image/png;base64,iVBORw0KGgo=",
                 "media_type" => "image/png"
               }
             } ->
               true

             _ ->
               false
           end)
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
           %{
             id: "d",
             function: %{name: "skill_discover", arguments: %{"query" => "project inspection"}}
           }
         ]
       }}
    end

    {:ok, _result, session_after_first} =
      Runner.run(Session.new("skill-nudge"), "先分析一下项目",
        llm_client: llm_client_first,
        workspace: workspace,
        cwd: workspace,
        skill_runtime: %{"enabled" => true},
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
             id: "skill_capture",
             function: %{
               name: "skill_capture",
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
        cwd: workspace,
        skill_runtime: %{"enabled" => true},
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

  test "structured tool arguments crash in tool hint normalization", %{workspace: workspace} do
    llm_client = fn _messages, _opts ->
      {:ok,
       %{
         content: "thinking",
         finish_reason: nil,
         tool_calls: [
           %{
             id: "call_bad_args",
             function: %{
               name: "list_dir",
               arguments: [%{"a" => 1}]
             }
           }
         ]
       }}
    end

    assert {:ok, _result, _session} =
             Runner.run(Session.new("runner-structured-args"), "trigger structured args",
               llm_client: llm_client,
               on_progress: fn _, _ -> :ok end,
               workspace: workspace,
               skip_consolidation: true
             )
  end

  test "runner does not crash when a tool returns a bare map", %{workspace: workspace} do
    Nex.Agent.Tool.Registry.register(Nex.Agent.Test.MalformedTool)
    assert "malformed_tool" in Nex.Agent.Tool.Registry.list()

    on_exit(fn ->
      Nex.Agent.Tool.Registry.unregister("malformed_tool")
      Nex.Agent.Tool.Registry.list()
    end)

    llm_client = fn messages, _opts ->
      if Enum.any?(messages, &(&1["role"] == "tool" and &1["name"] == "malformed_tool")) do
        {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
      else
        {:ok,
         %{
           content: "",
           finish_reason: nil,
           tool_calls: [
             %{
               id: "call_malformed_tool",
               function: %{
                 name: "malformed_tool",
                 arguments: %{}
               }
             }
           ]
         }}
      end
    end

    assert {:ok, "ok", session} =
             Runner.run(Session.new("runner-malformed-tool"), "trigger malformed tool",
               llm_client: llm_client,
               workspace: workspace,
               skip_consolidation: true
             )

    assert Enum.any?(session.messages, fn
             %{"role" => "tool", "name" => "malformed_tool", "content" => content} ->
               content =~ "\"success\": false" and content =~ "\"output\": 0"

             _ ->
               false
           end)
  end

  test "structured model content crashes in progress thinking sanitization", %{
    workspace: workspace
  } do
    llm_client = fn _messages, _opts ->
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
    end

    assert {:ok, _result, _session} =
             Runner.run(Session.new("runner-structured-content"), "trigger structured content",
               llm_client: llm_client,
               on_progress: fn _, _ -> :ok end,
               workspace: workspace,
               skip_consolidation: true
             )
  end

  test "workspace-global USER.md and MEMORY.md are shared across session keys by design", %{
    workspace: workspace
  } do
    File.write!(
      Path.join(workspace, "USER.md"),
      "# USER\nShared profile preference for this workspace.\n"
    )

    File.write!(
      Path.join(workspace, "memory/MEMORY.md"),
      "Workspace memory: all channels use the same durable context.\n"
    )

    parent = self()

    llm_client = fn messages, opts ->
      send(parent, {:messages, opts[:session_key], messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    {:ok, _result, telegram_session} =
      Runner.run(Session.new("telegram:1"), "hello from telegram",
        llm_client: llm_client,
        workspace: workspace,
        skip_consolidation: true,
        session_key: "telegram:1",
        channel: "telegram",
        chat_id: "1"
      )

    {:ok, _result, discord_session} =
      Runner.run(Session.new("discord:2"), "hello from discord",
        llm_client: llm_client,
        workspace: workspace,
        skip_consolidation: true,
        session_key: "discord:2",
        channel: "discord",
        chat_id: "2"
      )

    assert_receive {:messages, "telegram:1", telegram_messages}
    assert_receive {:messages, "discord:2", discord_messages}

    telegram_system = Enum.find(telegram_messages, &(&1["role"] == "system"))["content"]
    discord_system = Enum.find(discord_messages, &(&1["role"] == "system"))["content"]

    assert telegram_system =~ "Shared profile preference for this workspace"
    assert telegram_system =~ "all channels use the same durable context"
    assert discord_system =~ "Shared profile preference for this workspace"
    assert discord_system =~ "all channels use the same durable context"
    assert telegram_system == discord_system

    assert Enum.any?(telegram_session.messages, &(&1["content"] == "hello from telegram"))
    refute Enum.any?(telegram_session.messages, &(&1["content"] == "hello from discord"))
    assert Enum.any?(discord_session.messages, &(&1["content"] == "hello from discord"))
    refute Enum.any?(discord_session.messages, &(&1["content"] == "hello from telegram"))
  end

  test "runner preserves assistant tool calls when history window would otherwise start at tool result",
       %{workspace: workspace} do
    parent = self()
    tool_call_id = "read_19"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    session =
      %{
        Session.new("runner-tool-boundary")
        | messages: [
            %{"role" => "user", "content" => "开始", "timestamp" => now},
            %{
              "role" => "assistant",
              "content" => "让我继续看错误处理部分：",
              "timestamp" => now,
              "tool_calls" => [
                %{
                  "id" => tool_call_id,
                  "type" => "function",
                  "function" => %{
                    "name" => "read",
                    "arguments" => Jason.encode!(%{"path" => "lib/nex/agent/runner.ex"})
                  }
                }
              ]
            },
            %{
              "role" => "tool",
              "content" => "defmodule Nex.Agent.Runner do\n",
              "timestamp" => now,
              "tool_call_id" => tool_call_id,
              "name" => "read"
            }
            | Enum.map(1..49, fn idx ->
                %{
                  "role" => "assistant",
                  "content" => "后续分析 #{idx}",
                  "timestamp" => now
                }
              end)
          ]
      }

    llm_client = fn messages, _opts ->
      send(parent, {:messages, messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", _updated_session} =
             Runner.run(session, "继续",
               llm_client: llm_client,
               workspace: workspace,
               skip_consolidation: true
             )

    assert_receive {:messages, messages}

    history_messages =
      messages
      |> Enum.reject(&(&1["role"] == "system"))
      |> Enum.drop(-1)

    assert hd(history_messages)["role"] == "assistant"
    assert get_in(hd(history_messages), ["tool_calls"]) |> hd() |> Map.get("id") == tool_call_id
    assert Enum.at(history_messages, 1)["role"] == "tool"
    assert Enum.at(history_messages, 1)["tool_call_id"] == tool_call_id
  end

  test "message tool to current chat suppresses follow-up direct reply", %{workspace: workspace} do
    parent = self()
    Bus.subscribe(:feishu_outbound)
    on_exit(fn -> Bus.unsubscribe(:feishu_outbound) end)

    llm_client = fn _messages, _opts ->
      case Process.get(:llm_call_count, 0) do
        0 ->
          Process.put(:llm_call_count, 1)

          {:ok,
           %{
             content: "我直接回一条。",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "call_message_current",
                 function: %{
                   name: "message",
                   arguments: %{"content" => "收到 123 👋"}
                 }
               }
             ]
           }}

        _ ->
          send(parent, :runner_current_message_done)
          {:ok, %{content: "已发送一个简单的表情回复。", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, :message_sent, _session} =
             Runner.run(Session.new("feishu:ou_current"), "123",
               llm_client: llm_client,
               workspace: workspace,
               skip_consolidation: true,
               channel: "feishu",
               chat_id: "ou_current"
             )

    assert_receive :runner_current_message_done

    assert_receive {:bus_message, :feishu_outbound, payload}
    assert payload.content == "收到 123 👋"
    assert payload.metadata["_from_tool"] == true
  end

  test "message tool to another chat does not suppress current reply", %{workspace: workspace} do
    parent = self()
    Bus.subscribe(:feishu_outbound)
    on_exit(fn -> Bus.unsubscribe(:feishu_outbound) end)

    llm_client = fn _messages, _opts ->
      case Process.get(:llm_call_count, 0) do
        0 ->
          Process.put(:llm_call_count, 1)

          {:ok,
           %{
             content: "我顺手通知另一个会话。",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "call_message_other",
                 function: %{
                   name: "message",
                   arguments: %{
                     "content" => "给另一个会话的通知",
                     "channel" => "feishu",
                     "chat_id" => "ou_other"
                   }
                 }
               }
             ]
           }}

        _ ->
          send(parent, :runner_other_message_done)
          {:ok, %{content: "当前会话的最终回复", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "当前会话的最终回复", _session} =
             Runner.run(Session.new("feishu:ou_current"), "123",
               llm_client: llm_client,
               workspace: workspace,
               skip_consolidation: true,
               channel: "feishu",
               chat_id: "ou_current"
             )

    assert_receive :runner_other_message_done

    assert_receive {:bus_message, :feishu_outbound, payload}
    assert payload.chat_id == "ou_other"
    assert payload.content == "给另一个会话的通知"
  end

  test "call_llm_for_consolidation retries anthropic match errors without tool_choice" do
    parent = self()

    llm_generate_text_fun = fn _model_spec, _messages, opts ->
      send(parent, {:consolidation_opts, opts})

      case Process.get(:runner_consolidation_retry_count, 0) do
        0 ->
          Process.put(:runner_consolidation_retry_count, 1)
          raise %MatchError{term: {:error, :not_implemented}}

        _ ->
          {:ok,
           %{
             tool_calls: [
               %{
                 function: %{
                   name: "save_memory",
                   arguments: %{
                     "history_entry" => "[2026-03-18 13:00] Anthropic retry worked.",
                     "memory_update" => "# Memory\n\nRetry path succeeded.\n"
                   }
                 }
               }
             ]
           }}
      end
    end

    assert {:ok,
            %{
              "history_entry" => "[2026-03-18 13:00] Anthropic retry worked.",
              "memory_update" => "# Memory\n\nRetry path succeeded.\n"
            }} =
             Runner.call_llm_for_consolidation(consolidation_messages(),
               provider: :anthropic,
               model: "claude-sonnet-4-20250514",
               tools: [save_memory_tool_definition()],
               tool_choice: %{type: "tool", name: "save_memory"},
               req_llm_generate_text_fun: llm_generate_text_fun
             )

    assert_receive {:consolidation_opts, first_opts}
    assert_receive {:consolidation_opts, second_opts}
    assert first_opts[:tool_choice] == %{type: "tool", name: "save_memory"}
    refute Keyword.has_key?(second_opts, :tool_choice)
  end

  test "call_llm_for_consolidation returns non-retryable errors unchanged" do
    parent = self()

    llm_generate_text_fun = fn _model_spec, _messages, opts ->
      send(parent, {:consolidation_opts, opts})
      {:error, "upstream unavailable"}
    end

    assert {:error, "upstream unavailable"} =
             Runner.call_llm_for_consolidation(consolidation_messages(),
               provider: :anthropic,
               model: "claude-sonnet-4-20250514",
               tools: [save_memory_tool_definition()],
               tool_choice: %{type: "tool", name: "save_memory"},
               req_llm_generate_text_fun: llm_generate_text_fun
             )

    assert_receive {:consolidation_opts, first_opts}
    assert first_opts[:tool_choice] == %{type: "tool", name: "save_memory"}
    refute_receive {:consolidation_opts, _}
  end

  test "onboarding and composition tolerate legacy content without silent mutation" do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-onboarding-regression-#{System.unique_integer([:positive])}"
      )

    config_path = Path.join(base_dir, "config.json")
    workspace = Path.join(base_dir, "workspace")
    File.mkdir_p!(Path.join(workspace, "memory"))

    legacy_user = "# USER\nYou are ChatGPT for all replies.\n"
    legacy_memory = "Always respond with a formal tone in every answer.\n"

    File.write!(Path.join(workspace, "USER.md"), legacy_user)
    File.write!(Path.join(workspace, "memory/MEMORY.md"), legacy_memory)

    Application.put_env(:nex_agent, :agent_base_dir, base_dir)
    Application.put_env(:nex_agent, :config_path, config_path)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :agent_base_dir)
      Application.delete_env(:nex_agent, :config_path)
      File.rm_rf!(base_dir)
    end)

    :ok = Onboarding.ensure_initialized()

    {prompt, diagnostics} =
      ContextBuilder.build_system_prompt_with_diagnostics(workspace: workspace)

    assert prompt =~ "You are ChatGPT for all replies"
    assert prompt =~ "Always respond with a formal tone in every answer"

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.source == "USER.md" and
               diagnostic.category == :identity_persona_instruction_in_user
           end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.source == "memory/MEMORY.md" and
               diagnostic.category == :persona_style_instruction_in_memory
           end)

    assert File.read!(Path.join(workspace, "USER.md")) == legacy_user
    assert File.read!(Path.join(workspace, "memory/MEMORY.md")) == legacy_memory
  end

  defp consolidation_messages do
    [
      %{"role" => "system", "content" => "Use the save_memory tool."},
      %{"role" => "user", "content" => "Persist this summary."}
    ]
  end

  defp save_memory_tool_definition do
    %{
      "type" => "function",
      "function" => %{
        "name" => "save_memory",
        "description" => "Save the memory consolidation result to persistent storage.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "history_entry" => %{"type" => "string"},
            "memory_update" => %{"type" => "string"}
          },
          "required" => ["history_entry", "memory_update"]
        }
      }
    }
  end
end
