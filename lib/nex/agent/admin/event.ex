defmodule Nex.Agent.Admin.Event do
  @moduledoc false

  defstruct topic: "runtime",
            kind: "runtime.event",
            timestamp: nil,
            summary: nil,
            payload: %{}

  @type t :: %__MODULE__{
          topic: String.t(),
          kind: String.t(),
          timestamp: String.t(),
          summary: String.t(),
          payload: map()
        }

  @spec new(String.t(), String.t(), String.t(), map()) :: t()
  def new(topic, kind, summary, payload \\ %{}) do
    %__MODULE__{
      topic: normalize_topic(topic),
      kind: to_string(kind),
      timestamp: now_iso(),
      summary: to_string(summary),
      payload: stringify_keys(payload)
    }
  end

  @spec from_audit_entry(map()) :: t()
  def from_audit_entry(entry) when is_map(entry) do
    kind = Map.get(entry, "event", "runtime.event")
    payload = Map.get(entry, "payload", %{})

    %__MODULE__{
      topic: topic_for_kind(kind),
      kind: kind,
      timestamp: Map.get(entry, "timestamp", now_iso()),
      summary: summary_for(kind, payload),
      payload: stringify_keys(payload)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      "topic" => event.topic,
      "kind" => event.kind,
      "timestamp" => event.timestamp,
      "summary" => event.summary,
      "payload" => stringify_keys(event.payload || %{})
    }
  end

  @spec topic_for_kind(String.t()) :: String.t()
  def topic_for_kind(kind) when is_binary(kind) do
    kind
    |> String.split(".", parts: 2)
    |> List.first()
    |> normalize_topic()
  end

  @spec summary_for(String.t(), map()) :: String.t()
  def summary_for(kind, payload) when is_binary(kind) and is_map(payload) do
    case kind do
      "evolution.cycle_started" ->
        "Evolution cycle started"

      "evolution.cycle_completed" ->
        "Evolution cycle completed"

      "evolution.soul_updated" ->
        "SOUL updated"

      "evolution.memory_updated" ->
        "MEMORY updated"

      "evolution.skill_drafted" ->
        "Skill drafted: #{value(payload, "name", "unknown")}"

      "task.add" ->
        "Task added: #{value(payload, "title", "untitled")}"

      "task.update" ->
        "Task updated: #{value(payload, "title", "untitled")}"

      "cron.add" ->
        "Cron job added: #{value(payload, "name", "unnamed")}"

      "cron.update" ->
        "Cron job updated: #{value(payload, "name", "unnamed")}"

      "cron.remove" ->
        "Cron job removed: #{value(payload, "name", value(payload, "id", "unknown"))}"

      "cron.enable" ->
        "Cron job enabled: #{value(payload, "name", "unnamed")}"

      "cron.disable" ->
        "Cron job disabled: #{value(payload, "name", "unnamed")}"

      "cron.run" ->
        "Cron job triggered: #{value(payload, "name", "unnamed")}"

      "memory.consolidated" ->
        "Memory consolidation finished"

      "session.reset" ->
        "Session reset: #{value(payload, "session_key", "unknown")}"

      "runtime.gateway_started" ->
        "Gateway started"

      "runtime.gateway_stopped" ->
        "Gateway stopped"

      "code.hot_upgraded" ->
        "Hot upgrade applied: #{value(payload, "module", "unknown")}"

      "code.rollback" ->
        "Rollback applied: #{value(payload, "module", "unknown")}"

      _ ->
        kind
    end
  end

  defp normalize_topic("task"), do: "tasks"
  defp normalize_topic("cron"), do: "tasks"
  defp normalize_topic("memory"), do: "memory"
  defp normalize_topic("session"), do: "sessions"
  defp normalize_topic("code"), do: "code"
  defp normalize_topic("runtime"), do: "runtime"
  defp normalize_topic("evolution"), do: "evolution"
  defp normalize_topic(topic) when is_binary(topic) and topic != "", do: topic
  defp normalize_topic(_), do: "runtime"

  defp value(payload, key, default) do
    Map.get(payload, key) || Map.get(payload, to_string(key)) || default
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
