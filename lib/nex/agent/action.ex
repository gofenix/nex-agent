defmodule Nex.Agent.Action do
  @moduledoc """
  Dispatches evolution plans to concrete action executors.
  """

  alias Nex.Agent.Action.Code
  alias Nex.Agent.Action.Memory
  alias Nex.Agent.Action.Skill
  alias Nex.Agent.Action.Soul
  alias Nex.Agent.Action.Tool

  @spec execute(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute(%{"target_layer" => "none"} = plan, _ctx) do
    {:ok,
     %{
       status: "noop",
       layer: "none",
       plan: plan,
       action_result: nil,
       rollback: nil
     }}
  end

  def execute(%{"target_layer" => layer, "payload" => payload} = plan, ctx) do
    case dispatch(layer, payload, ctx) do
      {:ok, result} ->
        {:ok,
         %{
           status: "applied",
           layer: layer,
           plan: plan,
           action_result: result,
           rollback: Map.get(result, :rollback) || Map.get(result, "rollback")
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch("soul", payload, ctx), do: Soul.execute(payload, ctx)
  defp dispatch("memory", payload, ctx), do: Memory.execute(payload, ctx)
  defp dispatch("skill", payload, ctx), do: Skill.execute(payload, ctx)
  defp dispatch("tool", payload, ctx), do: Tool.execute(payload, ctx)
  defp dispatch("code", payload, ctx), do: Code.execute(payload, ctx)
  defp dispatch(layer, _payload, _ctx), do: {:error, "Unsupported target_layer: #{layer}"}
end
