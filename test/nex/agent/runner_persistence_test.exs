defmodule Nex.Agent.RunnerPersistenceTest do
  use ExUnit.Case, async: false

  alias Nex.Agent
  alias Nex.Agent.Runner
  alias Nex.Agent.Session
  alias Nex.Agent.SessionManager
  alias Nex.Agent.Tool.Registry, as: ToolRegistry

  setup do
    ensure_started(Nex.Agent.SessionManager, fn -> SessionManager.start_link() end)

    ensure_started(Nex.Agent.TaskSupervisor, fn ->
      Task.Supervisor.start_link(name: Nex.Agent.TaskSupervisor)
    end)

    ensure_started(Nex.Agent.Bus, fn -> Nex.Agent.Bus.start_link() end)
    ensure_started(ToolRegistry, fn -> ToolRegistry.start_link() end)

    :ok
  end

  test "Agent.prompt keeps the user message but does not persist assistant error responses" do
    chat_id = "error-persistence-#{System.unique_integer([:positive])}"
    session_key = "test:#{chat_id}"
    cleanup_session(session_key)

    {:ok, agent} = Agent.start(provider: :ollama, channel: "test", chat_id: chat_id)

    llm_client = fn _messages, _opts ->
      {:ok, %{content: "model transport failed", finish_reason: "error", tool_calls: []}}
    end

    assert {:error, "LLM returned an error", _agent} =
             Agent.prompt(agent, "trigger an llm error",
               channel: "test",
               chat_id: chat_id,
               llm_client: llm_client
             )

    persisted =
      wait_for_session_message_count(session_key, 1)

    assert [%{"role" => "user", "content" => "trigger an llm error"}] = persisted.messages
  end

  test "Runner.run persists assistant responses for successful stop responses" do
    session = Session.new(unique_session_key("stop-response"))

    llm_client = fn _messages, _opts ->
      {:ok, %{content: "all good", finish_reason: "stop", tool_calls: []}}
    end

    assert {:ok, "all good", final_session} =
             Runner.run(session, "say hi",
               provider: :ollama,
               channel: "test",
               chat_id: "stop-response",
               llm_client: llm_client
             )

    assert [
             %{"role" => "user", "content" => "say hi"},
             %{"role" => "assistant", "content" => "all good"}
           ] = final_session.messages
  end

  test "Runner.run preserves tool-call persistence behavior for successful tool turns" do
    session = Session.new(unique_session_key("tool-response"))

    llm_client = fn
      [_system, _user], _opts ->
        {:ok,
         %{
           content: "",
           finish_reason: "tool_calls",
           tool_calls: [
             %{
               "id" => "call_list_dir",
               "type" => "function",
               "function" => %{"name" => "list_dir", "arguments" => ~s({"path":"."})}
             }
           ]
         }}

      messages, _opts ->
        assert Enum.any?(messages, fn m ->
                 m["role"] == "tool" and m["tool_call_id"] == "call_list_dir"
               end)

        {:ok, %{content: "listed", finish_reason: "stop", tool_calls: []}}
    end

    assert {:ok, "listed", final_session} =
             Runner.run(session, "list the current directory",
               provider: :ollama,
               channel: "test",
               chat_id: "tool-response",
               llm_client: llm_client
             )

    assert [
             %{"role" => "user", "content" => "list the current directory"},
             %{"role" => "assistant", "tool_calls" => [%{"id" => "call_list_dir"}]},
             %{"role" => "tool", "tool_call_id" => "call_list_dir", "name" => "list_dir"},
             %{"role" => "assistant", "content" => "listed"}
           ] = final_session.messages
  end

  defp unique_session_key(suffix) do
    "test:#{suffix}:#{System.unique_integer([:positive])}"
  end

  defp wait_for_session_message_count(session_key, count, attempts \\ 20)

  defp wait_for_session_message_count(session_key, count, attempts) when attempts > 0 do
    case SessionManager.get(session_key) do
      %{messages: messages} = session when length(messages) == count ->
        session

      _ ->
        Process.sleep(25)
        wait_for_session_message_count(session_key, count, attempts - 1)
    end
  end

  defp wait_for_session_message_count(session_key, count, 0) do
    session = SessionManager.get(session_key) || SessionManager.get_or_create(session_key)
    flunk("expected #{count} messages for #{session_key}, got #{length(session.messages)}")
  end

  defp cleanup_session(session_key) do
    SessionManager.invalidate(session_key)
    File.rm_rf!(session_dir(session_key))
  end

  defp session_dir(session_key) do
    safe =
      session_key
      |> String.replace(":", "_")
      |> String.replace(~r/[^\w-]/, "_")

    Path.join([System.get_env("HOME", "~"), ".nex/agent/workspace/sessions", safe])
  end

  defp ensure_started(name, start_fn) do
    unless Process.whereis(name) do
      case start_fn.() do
        {:ok, pid} ->
          Process.unlink(pid)
          {:ok, pid}

        other ->
          other
      end
    end
  end
end
