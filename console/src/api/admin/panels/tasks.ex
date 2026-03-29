defmodule NexAgentConsole.Api.Admin.Panels.Tasks do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(_req) do
    Admin.tasks_state()
    |> then(&AdminUI.tasks_panel(%{state: &1}))
    |> View.render()
    |> Nex.html()
  end
end
