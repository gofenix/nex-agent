defmodule Nex.Agent.Reflect do
  @moduledoc """
  Internal reflection step for evolution planning.
  """

  @layer_order ["memory", "skill", "tool", "soul", "code"]

  @spec plan(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def plan(args, _ctx \\ %{}) do
    explicit_layer = Map.get(args, "target_layer")
    payload = normalize_payload(Map.get(args, "payload"))
    request = Map.get(args, "request")
    reason = Map.get(args, "reason")
    action_type = Map.get(args, "action_type")

    cond do
      explicit_layer in @layer_order ->
        {:ok,
         build_plan(
           explicit_layer,
           action_type || default_action_type(explicit_layer),
           reason || request || "Explicit evolve request",
           merge_payload(explicit_layer, payload, args)
         )}

      true ->
        {:ok, infer_plan(request, reason, payload, args)}
    end
  end

  defp infer_plan(request, reason, payload, args) do
    text =
      [request, reason, inspect(payload)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.find_value(@layer_order, default_none_plan(reason || request), fn layer ->
      if matches_layer?(layer, text, payload, args) do
        build_plan(
          layer,
          default_action_type(layer),
          reason || request || "Auto-reflected evolve request",
          merge_payload(layer, payload, args)
        )
      end
    end)
  end

  defp matches_layer?("memory", text, payload, _args) do
    has_payload?(payload, ["memory_update", "history_entry"]) or
      String.contains?(text, ["memory", "remember", "history", "recall"])
  end

  defp matches_layer?("skill", text, payload, _args) do
    (has_payload?(payload, ["name", "description", "content"]) and
       String.contains?(text, "skill")) or
      String.contains?(text, ["workflow", "repeatable task"])
  end

  defp matches_layer?("tool", text, payload, args) do
    (has_payload?(payload, ["name", "description", "content"]) and
       (String.contains?(text, "tool") or Map.has_key?(args, "tool_name"))) or
      String.contains?(text, ["capability", "custom tool", "workspace tool"])
  end

  defp matches_layer?("soul", text, payload, _args) do
    (has_payload?(payload, ["content"]) and String.contains?(text, "soul")) or
      String.contains?(text, ["personality", "behavior", "tone", "values"])
  end

  defp matches_layer?("code", text, payload, args) do
    has_payload?(payload, ["module", "code"]) or
      Map.has_key?(args, "module") or
      Map.has_key?(args, "code") or
      String.contains?(text, ["code", "module", "bug", "fix", "hot reload", "compile"])
  end

  defp default_none_plan(reason) do
    build_plan("none", "noop", reason || "No evolution action selected", %{})
  end

  defp build_plan(layer, action_type, reason, payload) do
    %{
      "target_layer" => layer,
      "action_type" => action_type,
      "reason" => reason,
      "payload" => payload
    }
  end

  defp default_action_type("memory"), do: "update_memory"
  defp default_action_type("skill"), do: "create_skill"
  defp default_action_type("tool"), do: "create_tool"
  defp default_action_type("soul"), do: "update_soul"
  defp default_action_type("code"), do: "patch_code"
  defp default_action_type(_), do: "noop"

  defp merge_payload("code", payload, args) do
    payload
    |> maybe_put("module", Map.get(args, "module"))
    |> maybe_put("code", Map.get(args, "code"))
  end

  defp merge_payload(_layer, payload, _args), do: payload

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put_new(map, key, value)

  defp normalize_payload(payload) when is_map(payload), do: payload
  defp normalize_payload(_), do: %{}

  defp has_payload?(payload, keys) do
    Enum.any?(keys, fn key ->
      case Map.get(payload, key) do
        value when is_binary(value) -> String.trim(value) != ""
        nil -> false
        _ -> true
      end
    end)
  end
end
