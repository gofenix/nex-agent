defmodule Nex.Agent.LLM.JsonRepair do
  @moduledoc """
  Repair malformed JSON from LLM tool call arguments.
  Handles common issues: trailing commas, single quotes, unquoted keys.
  """

  @doc """
  Attempt to repair and decode a malformed JSON string.
  Returns {:ok, map} on success, {:error, reason} on failure.
  """
  def repair_and_decode(input) when is_binary(input) do
    input
    |> String.trim()
    |> apply_repairs()
    |> Enum.find_value(fn json ->
      case Jason.decode(json) do
        {:ok, map} -> {:ok, map}
        _ -> nil
      end
    end)
    |> case do
      {:ok, _} = ok -> ok
      nil -> {:error, "Could not repair JSON"}
    end
  end

  def repair_and_decode(_), do: {:error, "Input is not a string"}

  defp apply_repairs(input) do
    [
      input,
      remove_trailing_commas(input),
      fix_single_quotes(input),
      fix_single_quotes(input) |> remove_trailing_commas(),
      wrap_bare_object(input)
    ]
    |> Enum.uniq()
  end

  defp remove_trailing_commas(json) do
    json
    |> String.replace(~r/,\s*}/, "}")
    |> String.replace(~r/,\s*\]/, "]")
  end

  defp fix_single_quotes(json) do
    String.replace(json, "'", "\"")
  end

  defp wrap_bare_object(json) do
    trimmed = String.trim(json)

    if not String.starts_with?(trimmed, "{") do
      "{#{trimmed}}"
    else
      trimmed
    end
  end
end
