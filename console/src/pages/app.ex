defmodule NexAgentConsole.Pages.App do
  use Nex

  alias NexAgentConsole.Components.AdminUI

  def render(assigns) do
    AdminUI.app(assigns)
  end
end
