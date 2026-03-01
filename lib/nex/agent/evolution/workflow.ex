defmodule Nex.Agent.Evolution.Workflow do
  @moduledoc """
  Evolution workflow orchestration with proposal queue.

  Flow:
  - evolve/3 evaluates risk policy
  - risky changes become proposals
  - approve_and_apply/1 applies proposal and records version
  """

  use Agent

  alias Nex.Agent.{Evolution, Memory}
  alias Nex.Agent.Evolution.Policy

  @name __MODULE__

  @type proposal :: %{
          id: String.t(),
          module: module(),
          code: String.t(),
          policy: map(),
          status: :pending | :approved | :rejected | :applied,
          created_at: String.t(),
          updated_at: String.t(),
          metadata: map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts ++ [name: @name])
  end

  @spec evolve(module(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def evolve(module, code, opts \\ []) do
    ensure_started()

    policy = Policy.assess(module, code, opts)

    if policy.require_approval do
      proposal = new_proposal(module, code, policy, Keyword.get(opts, :metadata, %{}))
      put_proposal(proposal)

      Memory.append(
        "Evolution proposal created: #{proposal.id}",
        "SUCCESS",
        %{type: :evolution_proposal, module: inspect(module), risk: policy.risk_level}
      )

      {:ok,
       %{
         status: :pending_approval,
         proposal_id: proposal.id,
         policy: policy
       }}
    else
      apply_change(module, code, policy)
    end
  end

  @spec list_pending() :: [proposal()]
  def list_pending do
    ensure_started()

    @name
    |> Agent.get(&Map.values/1)
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.sort_by(& &1.created_at)
  end

  @spec approve_and_apply(String.t()) :: {:ok, map()} | {:error, String.t()}
  def approve_and_apply(proposal_id) do
    ensure_started()

    case get_proposal(proposal_id) do
      nil ->
        {:error, "proposal not found: #{proposal_id}"}

      %{status: status} when status != :pending ->
        {:error, "proposal is not pending: #{proposal_id}"}

      proposal ->
        mark_status(proposal.id, :approved)

        case apply_change(proposal.module, proposal.code, proposal.policy) do
          {:ok, %{version: version}} = ok ->
            mark_status(proposal.id, :applied)

            {:ok,
             %{
               proposal_id: proposal.id,
               module: proposal.module,
               version: version
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec reject(String.t()) :: :ok | {:error, String.t()}
  def reject(proposal_id) do
    ensure_started()

    case get_proposal(proposal_id) do
      nil -> {:error, "proposal not found: #{proposal_id}"}
      _proposal ->
        mark_status(proposal_id, :rejected)
        :ok
    end
  end

  defp apply_change(module, code, policy) do
    case Evolution.upgrade_module(module, code) do
      {:ok, version} ->
        Memory.append(
          "Evolution applied: #{inspect(module)}",
          "SUCCESS",
          %{type: :evolution_apply, module: inspect(module), version: version.id, risk: policy.risk_level}
        )

        {:ok, %{status: :applied, version: version, policy: policy}}

      {:error, reason} ->
        Memory.append(
          "Evolution apply failed: #{inspect(module)}",
          "FAILURE",
          %{type: :evolution_apply, module: inspect(module), error: reason}
        )

        {:error, reason}
    end
  end

  defp ensure_started do
    unless Process.whereis(@name) do
      {:ok, _pid} = start_link()
    end
  end

  defp new_proposal(module, code, policy, metadata) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      id: proposal_id(),
      module: module,
      code: code,
      policy: policy,
      status: :pending,
      created_at: now,
      updated_at: now,
      metadata: metadata || %{}
    }
  end

  defp proposal_id do
    "prop_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  defp put_proposal(proposal) do
    Agent.update(@name, &Map.put(&1, proposal.id, proposal))
  end

  defp get_proposal(id) do
    Agent.get(@name, &Map.get(&1, id))
  end

  defp mark_status(id, status) do
    Agent.update(@name, fn proposals ->
      case Map.get(proposals, id) do
        nil -> proposals
        proposal ->
          Map.put(proposals, id, %{proposal | status: status, updated_at: DateTime.utc_now() |> DateTime.to_iso8601()})
      end
    end)
  end
end
