defmodule Nex.Agent.RunnerTimeoutTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Runner
  alias Nex.Agent.Session

  test "tool stream timeout follows tool call timeout with grace" do
    assert Runner.tool_stream_timeout_ms([
             {"call_1", "bash", %{"command" => "opencode", "timeout" => 600}}
           ]) == 605_000
  end

  test "tool stream timeout can come from run options for coding task prompts" do
    assert Runner.tool_stream_timeout_ms(
             [
               {"call_1", "bash", %{"command" => "opencode run issue"}}
             ],
             timeout: 1_800
           ) == 1_805_000
  end

  test "tool stream timeout keeps a default grace for ordinary tools" do
    assert Runner.tool_stream_timeout_ms([
             {"call_1", "list_dir", %{"path" => "."}}
           ]) == 125_000
  end

  test "first iteration tool restriction only exposes and forces the requested tool" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    parent = self()

    llm_client = fn _messages, opts ->
      iteration = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      tool_names = opts |> Keyword.fetch!(:tools) |> Enum.map(& &1["name"])
      send(parent, {:llm_call, iteration, tool_names, Keyword.get(opts, :tool_choice)})

      if iteration == 1 do
        {:ok,
         %{
           content: nil,
           finish_reason: nil,
           tool_calls: [
             %{
               "id" => "call_1",
               "name" => "opencode_run",
               "arguments" => %{}
             }
           ]
         }}
      else
        {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
      end
    end

    session = Session.new("github:gofenix")

    assert {:ok, "done", _session} =
             Runner.run(session, "github project pickup",
               llm_client: llm_client,
               workspace: System.tmp_dir!(),
               max_iterations: 2,
               skip_skills: true,
               schedule_memory_refresh: false,
               first_iteration_tool_only: ["opencode_run"],
               first_iteration_tool_choice: "opencode_run"
             )

    assert_receive {:llm_call, 1, ["opencode_run"], %{type: "tool", name: "opencode_run"}}
    assert_receive {:llm_call, 2, second_tools, nil}
    assert "bash" in second_tools
    assert "opencode_run" in second_tools
  end

  test "first iteration tool restriction blocks disallowed tool execution" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    llm_client = fn _messages, _opts ->
      iteration = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if iteration == 1 do
        {:ok,
         %{
           content: nil,
           finish_reason: nil,
           tool_calls: [
             %{
               "id" => "call_1",
               "name" => "bash",
               "arguments" => %{"command" => "touch should-not-run"}
             }
           ]
         }}
      else
        {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
      end
    end

    workspace =
      Path.join(System.tmp_dir!(), "nex-runner-first-tool-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    session = Session.new("github:gofenix")

    assert {:ok, "done", final_session} =
             Runner.run(session, "github project pickup",
               llm_client: llm_client,
               workspace: workspace,
               cwd: workspace,
               max_iterations: 2,
               skip_skills: true,
               schedule_memory_refresh: false,
               first_iteration_tool_only: ["opencode_run"],
               first_iteration_tool_choice: "opencode_run"
             )

    refute File.exists?(Path.join(workspace, "should-not-run"))

    assert Enum.any?(final_session.messages, fn message ->
             message["role"] == "tool" and message["name"] == "bash" and
               String.contains?(message["content"], "not allowed in this iteration")
           end)
  end
end
