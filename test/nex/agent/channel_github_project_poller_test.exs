defmodule Nex.Agent.Channel.GithubProjectPollerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Bus
  alias Nex.Agent.Channel.GithubProjectPoller

  @item_id "PVTI_test_item"
  @repo "gofenix/nex-agent"

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex_github_project_poller_#{System.unique_integer([:positive])}"
      )

    Bus.subscribe(:inbound)

    on_exit(fn ->
      Bus.unsubscribe(:inbound)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "clones a missing disposable checkout and publishes pickup metadata", %{
    workspace: workspace
  } do
    parent = self()
    item_list_args = GithubProjectPoller.item_list_args(2, "gofenix")
    clone_args = GithubProjectPoller.repo_clone_args(@repo, expected_work_dir(workspace))
    issue_view_args = GithubProjectPoller.issue_view_args(@repo, 12)
    comments_args = GithubProjectPoller.issue_comments_args(@repo, 12)

    run_fun = fn
      ^item_list_args ->
        {:ok, Jason.encode!(%{"items" => [project_item()]})}

      ^clone_args ->
        send(parent, {:gh, :clone, clone_args})
        File.mkdir_p!(expected_work_dir(workspace))
        {:ok, ""}

      ^issue_view_args ->
        {:ok,
         Jason.encode!(%{
           "title" => "add jp readme",
           "body" => "add jp",
           "labels" => [%{"name" => "opencode"}],
           "url" => "https://github.com/gofenix/nex-agent/issues/12"
         })}

      ^comments_args ->
        {:ok, Jason.encode!(%{"comments" => []})}

      ["project", "item-edit" | _] ->
        {:ok, ""}
    end

    start_supervised!(
      {GithubProjectPoller,
       enabled: true,
       owner: "gofenix",
       project_number: 2,
       workspace: workspace,
       work_root: "workspace/github",
       required_label: "opencode",
       todo_status: "Todo",
       doing_status: "In Progress",
       review_status: "In Progress",
       done_status: "Done",
       opencode_model: "opencode/test-model",
       poll_interval_ms: :manual,
       run_fun: run_fun}
    )

    assert_receive {:gh, :clone, _}
    assert_receive {:bus_message, :inbound, inbound}

    assert inbound.metadata._from_github_project == true
    assert inbound.metadata.work_dir == expected_work_dir(workspace)
    assert inbound.metadata.repo_path == expected_work_dir(workspace)
    assert inbound.metadata.branch == "codex/github-issue-12-PVTI_test_it"
    assert inbound.metadata.opencode_model == "opencode/test-model"

    assert File.dir?(expected_work_dir(workspace))
    assert registry_entry(workspace)["work_dir"] == expected_work_dir(workspace)
    assert registry_entry(workspace)["repo"] == @repo
  end

  test "reuses an existing item checkout without cloning again", %{workspace: workspace} do
    File.mkdir_p!(expected_work_dir(workspace))
    item_list_args = GithubProjectPoller.item_list_args(2, "gofenix")
    clone_args = GithubProjectPoller.repo_clone_args(@repo, expected_work_dir(workspace))
    issue_view_args = GithubProjectPoller.issue_view_args(@repo, 12)
    comments_args = GithubProjectPoller.issue_comments_args(@repo, 12)

    run_fun = fn
      ^item_list_args ->
        {:ok, Jason.encode!(%{"items" => [project_item()]})}

      ^clone_args ->
        send(self(), {:unexpected_clone, clone_args})
        {:error, :unexpected_clone}

      ^issue_view_args ->
        {:ok, Jason.encode!(%{"title" => "add jp readme", "body" => "add jp"})}

      ^comments_args ->
        {:ok, Jason.encode!(%{"comments" => []})}

      ["project", "item-edit" | _] ->
        {:ok, ""}
    end

    start_supervised!(
      {GithubProjectPoller,
       enabled: true,
       owner: "gofenix",
       project_number: 2,
       workspace: workspace,
       work_root: "workspace/github",
       required_label: "opencode",
       todo_status: "Todo",
       doing_status: "In Progress",
       review_status: "In Progress",
       done_status: "Done",
       poll_interval_ms: :manual,
       run_fun: run_fun}
    )

    assert_receive {:bus_message, :inbound, inbound}
    refute_receive {:unexpected_clone, _}, 100
    assert inbound.metadata.work_dir == expected_work_dir(workspace)
  end

  test "polls new nex issue comments for tracked project items without duplicate dispatch", %{
    workspace: workspace
  } do
    File.mkdir_p!(expected_work_dir(workspace))

    registry_path = Path.join(workspace, "tasks/github_items.json")
    File.mkdir_p!(Path.dirname(registry_path))

    File.write!(
      registry_path,
      Jason.encode!(%{
        @item_id => %{
          "status" => "review",
          "repo" => @repo,
          "issue_number" => 12,
          "issue_url" => "https://github.com/gofenix/nex-agent/issues/12",
          "work_dir" => expected_work_dir(workspace),
          "branch" => "codex/github-issue-12-PVTI_test_it",
          "pr_url" => "https://github.com/gofenix/nex-agent/pull/13",
          "last_comment_check" => "2026-06-03T15:40:00Z"
        }
      })
    )

    item_list_args = GithubProjectPoller.item_list_args(2, "gofenix")
    comments_args = GithubProjectPoller.issue_comments_args(@repo, 12)
    parent = self()

    run_fun = fn
      ^item_list_args ->
        {:ok, Jason.encode!(%{"items" => [project_item("In Progress")]})}

      ^comments_args ->
        send(parent, :comments_polled)

        {:ok,
         Jason.encode!(%{
           "comments" => [
             %{
               "id" => "old-comment",
               "body" => "@nex old request",
               "url" => "https://github.com/gofenix/nex-agent/issues/12#issuecomment-old",
               "createdAt" => "2026-06-03T15:39:00Z",
               "author" => %{"login" => "gofenix"}
             },
             %{
               "id" => "new-comment",
               "body" => "@nex 需要你额外增加一个韩文的readme",
               "url" => "https://github.com/gofenix/nex-agent/issues/12#issuecomment-new",
               "createdAt" => "2026-06-03T15:41:00Z",
               "author" => %{"login" => "gofenix"}
             }
           ]
         })}
    end

    pid =
      start_supervised!(
        {GithubProjectPoller,
         enabled: true,
         owner: "gofenix",
         project_number: 2,
         workspace: workspace,
         work_root: "workspace/github",
         required_label: "opencode",
         todo_status: "Todo",
         doing_status: "In Progress",
         review_status: "In Progress",
         done_status: "Done",
         opencode_model: "opencode/test-model",
         poll_interval_ms: :manual,
         run_fun: run_fun}
      )

    assert_receive :comments_polled
    assert_receive {:bus_message, :inbound, inbound}, 1_000

    assert inbound.channel == "github"
    assert inbound.chat_id == "#{@repo}#12"
    assert inbound.content == "@nex 需要你额外增加一个韩文的readme"
    assert inbound.metadata._from_github == true
    assert inbound.metadata.event_type == "issue_comment"
    assert inbound.metadata.comment_id == "new-comment"
    assert inbound.metadata.work_dir == expected_work_dir(workspace)
    assert inbound.metadata.branch == "codex/github-issue-12-PVTI_test_it"
    assert inbound.metadata.pr_url == "https://github.com/gofenix/nex-agent/pull/13"
    assert inbound.metadata.opencode_model == "opencode/test-model"

    registry = registry(workspace)
    assert registry[@item_id]["last_comment_id"] == "new-comment"
    assert registry[@item_id]["last_comment_url"] =~ "issuecomment-new"
    assert registry["#{@repo}#12"]["work_dir"] == expected_work_dir(workspace)

    send(pid, :poll)
    assert_receive :comments_polled
    refute_receive {:bus_message, :inbound, _}, 200
  end

  defp project_item(status \\ "Todo") do
    %{
      "id" => @item_id,
      "status" => status,
      "labels" => ["opencode"],
      "content" => %{
        "type" => "Issue",
        "repository" => @repo,
        "number" => 12,
        "url" => "https://github.com/gofenix/nex-agent/issues/12",
        "title" => "add jp readme",
        "body" => "add jp"
      }
    }
  end

  defp expected_work_dir(workspace) do
    Path.join([workspace, "github", "items", @item_id, "gofenix__nex-agent"])
  end

  defp registry_entry(workspace) do
    workspace
    |> registry()
    |> Map.fetch!(@item_id)
  end

  defp registry(workspace) do
    workspace
    |> Path.join("tasks/github_items.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
