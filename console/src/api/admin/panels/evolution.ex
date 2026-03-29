defmodule NexAgentConsole.Api.Admin.Panels.Evolution do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(_req) do
    Admin.evolution_state()
    |> then(&AdminUI.evolution_panel(%{state: &1}))
    |> View.render()
    |> Nex.html()
  end
end
