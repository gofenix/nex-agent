defmodule NexAgentConsole.Pages.Index do
  use Nex

  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 控制台",
      subtitle: "运行总览只提供状态与入口分发；真正的分层判断应回到六层进化页。",
      current_path: "/",
      panel_path: "/api/admin/panels/overview",
      primary_action_label: "查看六层",
      primary_action_href: "/evolution"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)
end
