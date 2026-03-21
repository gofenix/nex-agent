defmodule Nex.Agent.Audit do
  @moduledoc false

  alias Nex.Agent.Workspace

  @audit_file "events.jsonl"

  @spec append(String.t(), map(), keyword()) :: :ok
  def append(event, payload, opts \\ []) when is_binary(event) and is_map(payload) do
    Workspace.ensure!(opts)

    entry =
      %{
        "id" => generate_id(),
        "event" => event,
        "timestamp" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "payload" => stringify_keys(payload)
      }

    File.write!(audit_file(opts), Jason.encode!(entry) <> "\n", [:append])
    :ok
  end

  @spec recent(keyword()) :: [map()]
  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    audit_file(opts)
    |> read_jsonl()
    |> Enum.take(-limit)
    |> Enum.reverse()
  end

  @spec audit_file(keyword()) :: String.t()
  def audit_file(opts \\ []) do
    Path.join(Workspace.audit_dir(opts), @audit_file)
  end

  defp read_jsonl(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp generate_id do
    "audit_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
