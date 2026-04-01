defmodule NexAgentConsole.Pages.Tasks do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 任务",
      subtitle: "任务页只处理调度执行与 cron，不负责解释进化层该怎么分流。",
      current_path: "/tasks",
      panel_path: "/api/admin/panels/tasks",
      primary_action_label: "查看运行时",
      primary_action_href: "/runtime"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def run_job(req), do: cron_action(req.body["job_id"], :run)
  def enable_job(req), do: cron_action(req.body["job_id"], :enable)
  def disable_job(req), do: cron_action(req.body["job_id"], :disable)

  defp cron_action(job_id, :run) do
    case Admin.run_cron_job(job_id) do
      {:ok, _job} ->
        AdminUI.notice(%{title: "计划任务已触发", body: job_id, tone: "ok"})
        |> trigger("admin-event", %{topic: "tasks", summary: "Cron job triggered"})

      {:error, reason} ->
        AdminUI.notice(%{title: "触发失败", body: inspect(reason), tone: "danger"})
    end
  end

  defp cron_action(job_id, action) do
    enabled = action == :enable

    case Admin.enable_cron_job(job_id, enabled) do
      {:ok, _job} ->
        AdminUI.notice(%{
          title: if(enabled, do: "计划任务已启用", else: "计划任务已停用"),
          body: job_id,
          tone: if(enabled, do: "ok", else: "warn")
        })
        |> trigger("admin-event", %{topic: "tasks", summary: "Cron state changed"})

      {:error, reason} ->
        AdminUI.notice(%{
          title: "更新失败",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end
end
