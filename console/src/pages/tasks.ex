defmodule NexAgentConsole.Pages.Tasks do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | Tasks",
      eyebrow: "Tasks",
      subtitle: "任务摘要、cron job 启停，以及手动 run。",
      current_path: "/tasks",
      panel_path: "/api/admin/panels/tasks"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def run_job(req), do: cron_action(req.body["job_id"], :run)
  def enable_job(req), do: cron_action(req.body["job_id"], :enable)
  def disable_job(req), do: cron_action(req.body["job_id"], :disable)

  defp cron_action(job_id, :run) do
    case Admin.run_cron_job(job_id) do
      {:ok, _job} ->
        AdminUI.notice(%{title: "Cron triggered", body: job_id, tone: "ok"})
        |> trigger("admin-event", %{topic: "tasks", summary: "Cron job triggered"})

      {:error, reason} ->
        AdminUI.notice(%{title: "Cron trigger failed", body: inspect(reason), tone: "danger"})
    end
  end

  defp cron_action(job_id, action) do
    enabled = action == :enable

    case Admin.enable_cron_job(job_id, enabled) do
      {:ok, _job} ->
        AdminUI.notice(%{
          title: if(enabled, do: "Cron enabled", else: "Cron disabled"),
          body: job_id,
          tone: if(enabled, do: "ok", else: "warn")
        })
        |> trigger("admin-event", %{topic: "tasks", summary: "Cron state changed"})

      {:error, reason} ->
        AdminUI.notice(%{
          title: "Cron update failed",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end
end
