defmodule NexAgentConsole.Pages.Evolution do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | Evolution",
      eyebrow: "Evolution",
      subtitle: "观察 signals、审计时间线，并手动触发 evolution cycle。",
      current_path: "/evolution",
      panel_path: "/api/admin/panels/evolution"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def trigger_cycle(_req) do
    case Admin.run_evolution_cycle() do
      {:ok, result} ->
        AdminUI.notice(%{
          title: "Evolution cycle completed",
          body:
            "Soul #{result.soul_updates} / Memory #{result.memory_updates} / Skill drafts #{result.skill_candidates}",
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "evolution", summary: "Manual evolution cycle completed"})

      {:error, reason} ->
        AdminUI.notice(%{
          title: "Evolution cycle failed",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end
end
