defmodule NexAgentConsole.Pages.Memory do
  use Nex

  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | Memory",
      eyebrow: "Memory",
      subtitle: "查看 MEMORY / HISTORY / USER 三层持久化上下文。",
      current_path: "/memory",
      panel_path: "/api/admin/panels/memory"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)
end
