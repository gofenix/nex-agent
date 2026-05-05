defmodule NexAgentConsole.TracePagesTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Nex.Agent.{RequestTrace, Workspace}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-console-trace-pages-#{System.unique_integer([:positive])}"
      )

    Workspace.ensure!(workspace: workspace)

    Application.put_env(:nex_core, :app_module, "NexAgentConsole")
    Application.put_env(:nex_core, :src_path, "src")
    Nex.RouteDiscovery.clear_cache()

    if Process.whereis(Nex.Supervisor) == nil do
      start_supervised!(Nex.Supervisor)
    end

    trace_opts = [workspace: workspace, request_trace: %{"dir" => "audit/request_traces"}]
    trace_path = RequestTrace.trace_path("run_trace_page", trace_opts)
    File.mkdir_p!(Path.dirname(trace_path))

    File.write!(
      trace_path,
      [
        Jason.encode!(%{
          "type" => "request_started",
          "run_id" => "run_trace_page",
          "prompt" => "inspect the trace page",
          "channel" => "feishu",
          "chat_id" => "dev-room",
          "selected_packages" => [%{"name" => "agent-browser"}],
          "inserted_at" => "2026-05-05T12:00:00Z"
        }),
        Jason.encode!(%{
          "type" => "llm_request",
          "run_id" => "run_trace_page",
          "iteration" => 1,
          "messages" => [
            %{"role" => "system", "content" => "system prompt"},
            %{"role" => "user", "content" => "inspect the trace page"}
          ],
          "tools" => [
            %{
              "name" => "read",
              "description" => "Read a file",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{"path" => %{"type" => "string"}}
              }
            },
            %{
              "name" => "list_dir",
              "description" => "List files",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{"path" => %{"type" => "string"}}
              }
            }
          ],
          "inserted_at" => "2026-05-05T12:00:01Z"
        }),
        Jason.encode!(%{
          "type" => "llm_response",
          "run_id" => "run_trace_page",
          "iteration" => 1,
          "content" => "I will inspect it.",
          "tool_calls" => [
            %{"id" => "call_read", "name" => "read", "arguments" => %{"path" => "AGENTS.md"}}
          ],
          "inserted_at" => "2026-05-05T12:00:02Z"
        }),
        Jason.encode!(%{
          "type" => "tool_result",
          "run_id" => "run_trace_page",
          "tool" => "list_dir",
          "content" => "done",
          "inserted_at" => "2026-05-05T12:00:03Z"
        }),
        Jason.encode!(%{
          "type" => "request_completed",
          "run_id" => "run_trace_page",
          "status" => "completed",
          "result" => "final answer",
          "inserted_at" => "2026-05-05T12:00:04Z"
        })
      ]
      |> Enum.join("\n")
    )

    on_exit(fn ->
      Nex.RouteDiscovery.clear_cache()
      Application.delete_env(:nex_core, :app_module)
      Application.delete_env(:nex_core, :src_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "root redirects to traces" do
    conn = Nex.Router.call(conn(:get, "/"), [])

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/traces"]
  end

  test "trace list renders conversation rows with exact timestamps", %{workspace: workspace} do
    conn =
      :get
      |> conn("/traces?workspace=#{URI.encode(workspace)}")
      |> Nex.Router.call([])

    assert conn.status == 200
    assert conn.resp_body =~ "Trace conversations"
    assert conn.resp_body =~ "inspect the trace page"
    assert conn.resp_body =~ "2026-05-05 12:00:00"
    refute conn.resp_body =~ "Today"
    refute conn.resp_body =~ "Yesterday"
    assert conn.resp_body =~ "/traces/run_trace_page"
  end

  test "trace detail renders timeline and raw events", %{workspace: workspace} do
    conn =
      :get
      |> conn("/traces/run_trace_page?workspace=#{URI.encode(workspace)}")
      |> Nex.Router.call([])

    assert conn.status == 200
    assert conn.resp_body =~ "Back to traces"
    assert conn.resp_body =~ "inspect the trace page"
    assert conn.resp_body =~ "Started 2026-05-05 12:00:00"
    assert conn.resp_body =~ "Completed 2026-05-05 12:00:04"
    assert conn.resp_body =~ "request_started"
    assert conn.resp_body =~ "llm_request"
    assert conn.resp_body =~ "llm_response"
    assert conn.resp_body =~ "messages (2)"
    assert conn.resp_body =~ "available tools (2)"
    assert conn.resp_body =~ "Read a file"
    assert conn.resp_body =~ "tool calls (1)"
    assert conn.resp_body =~ "call_read"
    assert conn.resp_body =~ "AGENTS.md"
    assert conn.resp_body =~ "tool_result"
    assert conn.resp_body =~ "request_completed"
    assert conn.resp_body =~ "Raw JSONL events"
  end

  test "missing trace returns 404", %{workspace: workspace} do
    conn =
      :get
      |> conn("/traces/not_found?workspace=#{URI.encode(workspace)}")
      |> Nex.Router.call([])

    assert conn.status == 404
  end
end
