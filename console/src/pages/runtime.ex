defmodule NexAgentConsole.Pages.Runtime do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 运行时",
      subtitle: "运行时页只负责 gateway、services 和 heartbeat 的操作与健康检查。",
      current_path: "/runtime",
      panel_path: "/api/admin/panels/runtime",
      primary_action_label: "进入进化台",
      primary_action_href: "/evolution"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def start_gateway(_req) do
    case Admin.start_gateway() do
      :ok ->
        AdminUI.notice(%{title: "网关已启动", body: "runtime is now live", tone: "ok"})
        |> trigger("admin-event", %{topic: "runtime", summary: "Gateway started"})

      {:error, reason} ->
        AdminUI.notice(%{title: "启动失败", body: inspect(reason), tone: "danger"})
    end
  end

  def stop_gateway(_req) do
    case Admin.stop_gateway() do
      :ok ->
        AdminUI.notice(%{title: "网关已停止", body: "runtime stopped", tone: "warn"})
        |> trigger("admin-event", %{topic: "runtime", summary: "Gateway stopped"})

      {:error, reason} ->
        AdminUI.notice(%{title: "停止失败", body: inspect(reason), tone: "danger"})
    end
  end
end
