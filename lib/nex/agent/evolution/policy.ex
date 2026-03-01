defmodule Nex.Agent.Evolution.Policy do
  @moduledoc """
  Risk policy for autonomous code evolution.
  """

  @default_require_approval true

  @high_risk_modules [
    Nex.Agent.Runner,
    Nex.Agent.Security,
    Nex.Agent.Tool.Bash,
    Nex.Agent.Evolution,
    Nex.Agent.Evolution.Workflow
  ]

  @spec assess(module(), String.t(), keyword()) :: map()
  def assess(module, code, opts \\ []) do
    auto_approve = Keyword.get(opts, :auto_approve, false)

    risk_level =
      cond do
        module in @high_risk_modules -> :high
        String.contains?(code, "System.cmd") -> :high
        String.contains?(code, "File.rm_rf") -> :high
        String.contains?(code, "Code.eval_string") -> :high
        String.length(code) > 12_000 -> :medium
        true -> :low
      end

    require_approval =
      Keyword.get(opts, :require_approval, @default_require_approval) and
        not auto_approve and
        risk_level in [:high, :medium]

    %{
      module: module,
      risk_level: risk_level,
      require_approval: require_approval,
      reasons: reasons(module, code, risk_level)
    }
  end

  @spec enforce(module(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def enforce(module, code, opts \\ []) do
    policy = assess(module, code, opts)

    if policy.require_approval do
      {:error, "approval_required"}
    else
      :ok
    end
  end

  @spec high_risk_modules() :: [module()]
  def high_risk_modules, do: @high_risk_modules

  defp reasons(module, code, risk_level) do
    []
    |> maybe_add(module in @high_risk_modules, "module is high-impact")
    |> maybe_add(String.contains?(code, "System.cmd"), "contains System.cmd")
    |> maybe_add(String.contains?(code, "File.rm_rf"), "contains File.rm_rf")
    |> maybe_add(String.contains?(code, "Code.eval_string"), "contains Code.eval_string")
    |> maybe_add(String.length(code) > 12_000, "large patch size")
    |> case do
      [] -> ["risk=#{risk_level}"]
      reasons -> reasons
    end
  end

  defp maybe_add(list, true, reason), do: list ++ [reason]
  defp maybe_add(list, false, _reason), do: list
end
