defmodule NexAgentConsole.Api.Admin.Panels.Sessions do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(req) do
    session_key = req.query["session_key"]

    Admin.sessions_state(session_key: session_key)
    |> then(&AdminUI.sessions_panel(%{state: &1}))
    |> View.render()
    |> Nex.html()
  end
end
