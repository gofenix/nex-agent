defmodule Nex.Agent.PersonalSummaryTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.PersonalSummary

  setup do
    prefix = "personal:"

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-personal-summary-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    on_exit(fn ->
      if Process.whereis(Nex.Agent.Cron) do
        Nex.Agent.Cron.list_jobs(workspace: workspace)
        |> Enum.filter(&String.starts_with?(&1.name, prefix))
        |> Enum.each(fn job -> Nex.Agent.Cron.remove_job(job.id, workspace: workspace) end)
      end

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "default summary jobs only auto-enable for personal chats and stay deduplicated", %{
    workspace: workspace
  } do
    if Process.whereis(Nex.Agent.Cron) do
      group_chat_id = "oc_group_#{System.unique_integer([:positive])}"
      dm_chat_id = "ou_user_#{System.unique_integer([:positive])}"

      PersonalSummary.ensure_default_jobs("feishu", group_chat_id,
        metadata: %{"chat_type" => "group"},
        workspace: workspace
      )

      refute Enum.any?(
               Nex.Agent.Cron.list_jobs(workspace: workspace),
               &String.ends_with?(&1.name, group_chat_id)
             )

      1..4
      |> Task.async_stream(
        fn _ ->
          PersonalSummary.ensure_default_jobs("feishu", dm_chat_id,
            metadata: %{"chat_type" => "p2p"},
            workspace: workspace
          )
        end,
        timeout: 5_000
      )
      |> Stream.run()

      jobs =
        Nex.Agent.Cron.list_jobs(workspace: workspace)
        |> Enum.filter(&String.ends_with?(&1.name, dm_chat_id))

      assert length(jobs) == 2
      assert Enum.any?(jobs, &String.starts_with?(&1.name, "personal:daily-summary:feishu:"))
      assert Enum.any?(jobs, &String.starts_with?(&1.name, "personal:weekly-summary:feishu:"))
    end
  end
end
