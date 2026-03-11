defmodule Nex.Agent.Action.Soul do
  @moduledoc false

  @spec execute(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute(payload, _ctx) do
    content = Map.get(payload, "content")

    if is_binary(content) and String.trim(content) != "" do
      soul_path =
        Path.join([System.get_env("HOME", "."), ".nex", "agent", "workspace", "SOUL.md"])

      dir = Path.dirname(soul_path)
      File.mkdir_p!(dir)

      case File.write(soul_path, content) do
        :ok -> {:ok, %{updated: true, path: soul_path}}
        {:error, reason} -> {:error, "Error updating SOUL.md: #{inspect(reason)}"}
      end
    else
      {:error, "soul action requires content"}
    end
  end
end
