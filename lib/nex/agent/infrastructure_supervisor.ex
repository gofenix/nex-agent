defmodule Nex.Agent.InfrastructureSupervisor do
  @moduledoc """
  Supervisor for infrastructure services: Bus, Tool.Registry, Memory.Index, Cron, Heartbeat.

  All children are independent (:one_for_one) — one crashing does not affect others.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Nex.Agent.Bus,
      Nex.Agent.Tool.Registry,
      Nex.Agent.Memory.Index,
      Nex.Agent.MCP.ServerManager,
      Nex.Agent.Cron,
      Nex.Agent.Heartbeat
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
