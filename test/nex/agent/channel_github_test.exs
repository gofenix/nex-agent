defmodule Nex.Agent.Channel.GithubTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Channel.Github

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex_github_event_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "tasks"))
    test_pid = self()
    publish_fun = fn topic, inbound -> send(test_pid, {:published, topic, inbound}) end

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, publish_fun: publish_fun}
  end

  test "issue comment with nex mention publishes one generic github inbound", %{
    workspace: workspace,
    publish_fun: publish_fun
  } do
    File.write!(
      Path.join([workspace, "tasks", "github_items.json"]),
      Jason.encode!(%{
        "gofenix/nex-agent#12" => %{
          "branch" => "codex/issue-12",
          "pr_url" => "https://github.com/gofenix/nex-agent/pull/13",
          "last_status" => "in_review"
        }
      })
    )

    event = issue_comment_event("@nex 这个 case 还不对，空输入应该直接报错")

    assert :ok =
             Github.ingest_event(event,
               event_type: "issue_comment",
               workspace: workspace,
               publish_fun: publish_fun
             )

    assert_receive {:published, :inbound, inbound}, 500
    assert inbound.channel == "github"
    assert inbound.chat_id == "gofenix/nex-agent#12"
    assert inbound.content == "@nex 这个 case 还不对，空输入应该直接报错"
    assert inbound.workspace == workspace
    assert inbound.metadata._from_github == true
    assert inbound.metadata.event_type == "issue_comment"
    assert inbound.metadata.repo == "gofenix/nex-agent"
    assert inbound.metadata.issue_number == 12
    assert inbound.metadata.issue_title == "Fix empty input"
    assert inbound.metadata.issue_body == "Current implementation accepts empty input."
    assert inbound.metadata.comment_id == 9001
    assert inbound.metadata.comment_author == "fenix"

    assert inbound.metadata.comment_url ==
             "https://github.com/gofenix/nex-agent/issues/12#issuecomment-9001"

    assert inbound.metadata.pr_url == "https://github.com/gofenix/nex-agent/pull/13"
    assert inbound.metadata.registry["branch"] == "codex/issue-12"
    assert inbound.metadata.registry["last_status"] == "in_review"
    refute Map.has_key?(inbound.metadata, :action)

    assert Github.ingest_event(event,
             event_type: "issue_comment",
             workspace: workspace,
             publish_fun: publish_fun
           ) ==
             {:ignore, :duplicate}

    refute_receive {:published, :inbound, _}, 100
  end

  test "comment without nex mention exits without inbound or token work", %{
    workspace: workspace,
    publish_fun: publish_fun
  } do
    event = issue_comment_event("这个 case 还不对，空输入应该直接报错")

    assert Github.ingest_event(event,
             event_type: "issue_comment",
             workspace: workspace,
             publish_fun: publish_fun
           ) ==
             {:ignore, :missing_wake_word}

    refute_receive {:published, :inbound, _}, 100
  end

  defp issue_comment_event(body) do
    %{
      "comment" => %{
        "id" => 9001,
        "body" => body,
        "html_url" => "https://github.com/gofenix/nex-agent/issues/12#issuecomment-9001",
        "user" => %{"login" => "fenix"}
      },
      "issue" => %{
        "number" => 12,
        "title" => "Fix empty input",
        "body" => "Current implementation accepts empty input.",
        "html_url" => "https://github.com/gofenix/nex-agent/issues/12",
        "pull_request" => %{"html_url" => "https://github.com/gofenix/nex-agent/pull/13"}
      },
      "repository" => %{
        "full_name" => "gofenix/nex-agent",
        "html_url" => "https://github.com/gofenix/nex-agent",
        "default_branch" => "main"
      },
      "sender" => %{"login" => "fenix"}
    }
  end
end
