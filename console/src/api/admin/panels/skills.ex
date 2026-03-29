defmodule NexAgentConsole.Api.Admin.Panels.Skills do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(_req) do
    Admin.skills_state()
    |> then(&AdminUI.skills_panel(%{state: &1}))
    |> View.render()
    |> Nex.html()
  end
end
