defmodule NexAgentConsole.Pages.Index do
  use Nex

  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 总览",
      eyebrow: "Overview",
      subtitle: "单实例运行时概览，聚合 evolution、任务、会话与最近热更。",
      current_path: "/",
      panel_path: "/api/admin/panels/overview"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)
end
