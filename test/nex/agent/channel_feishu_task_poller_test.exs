defmodule Nex.Agent.Channel.FeishuTaskPollerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Bus
  alias Nex.Agent.Channel.FeishuTaskPoller

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    workspace =
      Path.join(System.tmp_dir!(), "nex_feishu_task_poller_#{System.unique_integer([:positive])}")

    Bus.subscribe(:inbound)

    on_exit(fn ->
      Bus.unsubscribe(:inbound)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "first poll records baseline without dispatching old tasks", %{workspace: workspace} do
    default_args = FeishuTaskPoller.default_list_args()
    completed_args = FeishuTaskPoller.completed_list_args()

    run_fun = fn
      ^default_args ->
        {:ok, Jason.encode!(%{"items" => [task("task_old", "old task")]})}

      ^completed_args ->
        {:ok, Jason.encode!(%{"items" => []})}

      args when hd(args) == "api" ->
        {:ok, Jason.encode!(%{"data" => %{"items" => []}})}
    end

    pid =
      start_supervised!(
        {FeishuTaskPoller,
         enabled: true, workspace: workspace, run_fun: run_fun, poll_interval_ms: :manual}
      )

    send(pid, :poll)

    refute_receive {:bus_message, :inbound, _}, 100
    assert File.exists?(Path.join([workspace, "tasks", "poll_state.json"]))
  end

  test "second poll dispatches newly discovered tasks", %{workspace: workspace} do
    {:ok, task_agent} = Agent.start_link(fn -> [[task("task_old", "old task")]] end)
    default_args = FeishuTaskPoller.default_list_args()
    completed_args = FeishuTaskPoller.completed_list_args()

    run_fun = fn
      ^default_args ->
        tasks = Agent.get_and_update(task_agent, fn [head | tail] -> {head, tail} end)
        {:ok, Jason.encode!(%{"items" => tasks})}

      ^completed_args ->
        {:ok, Jason.encode!(%{"items" => []})}

      args when hd(args) == "api" ->
        {:ok, Jason.encode!(%{"data" => %{"items" => []}})}
    end

    pid =
      start_supervised!(
        {FeishuTaskPoller,
         enabled: true, workspace: workspace, run_fun: run_fun, poll_interval_ms: :manual}
      )

    send(pid, :poll)
    refute_receive {:bus_message, :inbound, _}, 100

    Agent.update(task_agent, fn _ ->
      [[task("task_old", "old task"), task("task_new", "test: list repo files")]]
    end)

    send(pid, :poll)

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.channel == "feishu"
    assert inbound.chat_id == "ou_user"
    assert inbound.content == "/run_feishu_task task_new"
    assert inbound.metadata._from_feishu_task == true
    assert inbound.metadata.task_id == "task_new"
    assert inbound.metadata.task_title == "test: list repo files"
    assert inbound.metadata.task_action == "created"
  end

  test "reopened completed tasks dispatch as rerun", %{workspace: workspace} do
    default_args = FeishuTaskPoller.default_list_args()
    completed_args = FeishuTaskPoller.completed_list_args()

    initial_state = %{
      "tasks" => %{
        "task_1" => %{
          "status" => "completed",
          "signature" => "task_1|completed|old-update|old title|"
        }
      }
    }

    File.mkdir_p!(Path.join(workspace, "tasks"))
    File.write!(Path.join([workspace, "tasks", "poll_state.json"]), Jason.encode!(initial_state))

    run_fun = fn
      ^default_args ->
        {:ok,
         Jason.encode!(%{
           "items" => [
             task("task_1", "old title", %{
               "status" => "in_progress",
               "updated_at" => "new-update"
             })
           ]
         })}

      ^completed_args ->
        {:ok, Jason.encode!(%{"items" => []})}

      args when hd(args) == "api" ->
        {:ok, Jason.encode!(%{"data" => %{"items" => []}})}
    end

    pid =
      start_supervised!(
        {FeishuTaskPoller,
         enabled: true, workspace: workspace, run_fun: run_fun, poll_interval_ms: :manual}
      )

    send(pid, :poll)

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.content == "/rerun_feishu_task task_1"
    assert inbound.metadata.task_action == "rerun"
  end

  test "uses lark-cli get-my-tasks with json output" do
    assert FeishuTaskPoller.default_list_args() == [
             "task",
             "+get-my-tasks",
             "--as",
             "user",
             "--format",
             "json",
             "--page-all"
           ]

    assert FeishuTaskPoller.completed_list_args() == [
             "task",
             "+get-my-tasks",
             "--as",
             "user",
             "--format",
             "json",
             "--page-all",
             "--complete"
           ]

    [api, method, path | _] = FeishuTaskPoller.comments_args("task_1")
    assert api == "api"
    assert method == "GET"
    assert path == "/open-apis/task/v2/comments"
  end

  test "unseen rerun comments dispatch as rerun", %{workspace: workspace} do
    default_args = FeishuTaskPoller.default_list_args()
    completed_args = FeishuTaskPoller.completed_list_args()
    task = task("task_1", "old title")

    File.mkdir_p!(Path.join(workspace, "tasks"))

    File.write!(
      Path.join([workspace, "tasks", "poll_state.json"]),
      Jason.encode!(%{
        "initialized" => true,
        "tasks" => %{"task_1" => %{"status" => "open", "signature" => "task_1|open|||"}},
        "comments" => %{"task_1" => %{}}
      })
    )

    run_fun = fn
      ^default_args ->
        {:ok, Jason.encode!(%{"items" => [task]})}

      ^completed_args ->
        {:ok, Jason.encode!(%{"items" => []})}

      args when hd(args) == "api" ->
        {:ok,
         Jason.encode!(%{
           "data" => %{
             "items" => [
               %{
                 "comment_id" => "comment_1",
                 "content" => "/rerun",
                 "creator" => %{"id" => "ou_user", "type" => "user"}
               }
             ]
           }
         })}
    end

    pid =
      start_supervised!(
        {FeishuTaskPoller,
         enabled: true, workspace: workspace, run_fun: run_fun, poll_interval_ms: :manual}
      )

    send(pid, :poll)

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.chat_id == "ou_user"
    assert inbound.content == "/rerun_feishu_task task_1"
    assert inbound.metadata.task_action == "rerun"
    assert inbound.metadata.operator_user_id == "ou_user"
  end

  defp task(id, title, attrs \\ %{}) do
    Map.merge(
      %{
        "guid" => id,
        "summary" => title,
        "description" => "do work",
        "status" => "open",
        "updated_at" => id <> "-updated",
        "creator_id" => "ou_user"
      },
      attrs
    )
  end
end
