defmodule NexAgentConsole.Api.Admin.Panels.Runtime do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(_req) do
    Admin.runtime_state()
    |> then(&AdminUI.runtime_panel(%{state: &1}))
    |> View.render()
    |> Nex.html()
  end
end
