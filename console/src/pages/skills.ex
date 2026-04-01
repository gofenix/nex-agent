defmodule NexAgentConsole.Pages.Skills do
  use Nex

  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 能力层",
      subtitle: "能力层把 SKILL 与 TOOL 放在一起看，但明确区分方法沉淀和确定性能力。",
      current_path: "/skills",
      panel_path: "/api/admin/panels/skills",
      primary_action_label: "查看代码变更",
      primary_action_href: "/code"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)
end
