defmodule Nex.Agent.Evolve do
  @moduledoc """
  Unified evolution entrypoint: reflect, plan, and execute.
  """

  alias Nex.Agent.Action
  alias Nex.Agent.Reflect

  @spec execute(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute(args, ctx \\ %{}) do
    with {:ok, plan} <- Reflect.plan(args, ctx),
         {:ok, result} <- Action.execute(plan, ctx) do
      {:ok,
       %{
         status: result.status,
         layer: result.layer,
         plan: result.plan,
         action_result: result.action_result,
         rollback: result.rollback
       }}
    end
  end
end
