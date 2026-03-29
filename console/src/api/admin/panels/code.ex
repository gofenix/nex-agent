defmodule NexAgentConsole.Api.Admin.Panels.Code do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(req) do
    Admin.code_state(module: req.query["module"])
    |> then(&AdminUI.code_panel(%{state: &1}))
    |> View.render()
    |> Nex.html()
  end
end
