defmodule NexAgentConsole.Pages.Skills do
  use Nex

  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | Skills",
      eyebrow: "Skills",
      subtitle: "本地 skills、runtime packages、谱系与近期 runs。",
      current_path: "/skills",
      panel_path: "/api/admin/panels/skills"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)
end
