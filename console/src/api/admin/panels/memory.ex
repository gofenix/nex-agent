defmodule NexAgentConsole.Api.Admin.Panels.Memory do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(_req) do
    Admin.memory_state()
    |> then(&AdminUI.memory_panel(%{state: &1}))
    |> View.render()
    |> Nex.html()
  end
end
