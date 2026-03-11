defmodule Nex.Agent.WorkerSupervisor do
  @moduledoc """
  Supervisor for worker services: InboundWorker, Subagent.

  All children are independent (:one_for_one). Each worker loads its own config
  during init so the supervisor can restart them without config parameters.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Nex.Agent.InboundWorker,
      Nex.Agent.Subagent
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
