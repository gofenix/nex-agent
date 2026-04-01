defmodule NexAgentConsole.Pages.Evolution do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 分层进化",
      subtitle: "这里先判断变化该落到 SOUL、USER、MEMORY、SKILL、TOOL 还是 CODE，再决定是否手动运行。",
      current_path: "/evolution",
      panel_path: "/api/admin/panels/evolution",
      primary_action_label: "跳到手动运行",
      primary_action_href: "#manual-cycle"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def trigger_cycle(_req) do
    case Admin.run_evolution_cycle() do
      {:ok, result} ->
        AdminUI.notice(%{
          title: "Evolution cycle 已完成",
          body:
            "Soul #{result.soul_updates} / Memory #{result.memory_updates} / Skill drafts #{result.skill_candidates}",
          tone: "ok"
        })
        |> trigger("admin-event", %{
          topic: "evolution",
          summary: "Manual evolution cycle completed"
        })

      {:error, reason} ->
        AdminUI.notice(%{
          title: "Evolution cycle 失败",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end
end
