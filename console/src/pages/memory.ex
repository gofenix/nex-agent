defmodule NexAgentConsole.Pages.Memory do
  use Nex

  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 认知记忆",
      subtitle: "认知层聚焦 SOUL、USER、MEMORY 与 HISTORY，不和能力层或代码层混在一起。",
      current_path: "/memory",
      panel_path: "/api/admin/panels/memory",
      primary_action_label: "检查会话",
      primary_action_href: "/sessions"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)
end
