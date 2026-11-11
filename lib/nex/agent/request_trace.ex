defmodule Nex.Agent.RequestTrace do
  @moduledoc false

  alias Nex.Agent.{Config, Workspace}

  @spec default_config() :: map()
  def default_config do
    %{
      "enabled" => false,
      "dir" => "audit/request_traces"
    }
  end

  @spec config(keyword()) :: map()
  def config(opts \\ []) do
    config =
      Keyword.get_lazy(opts, :config, fn ->
        Config.load(config_path: Keyword.get(opts, :config_path))
      end)

    base = Config.request_trace(config)

    Map.merge(base, Keyword.get(opts, :request_trace, %{}))
  end

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    config(opts)["enabled"] == true
  end

  @spec traces_dir(keyword()) :: String.t()
  def traces_dir(opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || Workspace.root(opts)
    custom = config(opts)["dir"]

    cond do
      is_binary(custom) and Path.type(custom) == :absolute ->
        custom

      is_binary(custom) and custom != "" ->
        Path.join(workspace, custom)

      true ->
        Path.join(workspace, "audit/request_traces")
    end
  end

  @spec trace_path(String.t(), keyword()) :: String.t()
  def trace_path(run_id, opts \\ []) when is_binary(run_id) do
    Path.join(traces_dir(opts), "#{run_id}.jsonl")
  end

  @spec append_event(map(), keyword()) :: {:ok, String.t()} | :ok | {:error, String.t()}
  def append_event(event, opts \\ []) when is_map(event) do
    if enabled?(opts) do
      run_id = event[:run_id] || event["run_id"]

      if is_binary(run_id) and run_id != "" do
        path = trace_path(run_id, opts)
        File.mkdir_p!(Path.dirname(path))

        line =
          event
          |> Map.put_new(:inserted_at, DateTime.utc_now() |> DateTime.to_iso8601())
          |> sanitize_value()
          |> Jason.encode!()

        File.write!(path, line <> "\n", [:append])
        {:ok, path}
      else
        {:error, "request trace event missing run_id"}
      end
    else
      :ok
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @spec list_paths(keyword()) :: [String.t()]
  def list_paths(opts \\ []) do
    dir = traces_dir(opts)

    if File.dir?(dir) do
      dir
      |> Path.join("*.jsonl")
      |> Path.wildcard()
      |> Enum.sort_by(&file_timestamp/1, {:desc, DateTime})
    else
      []
    end
  end

  @spec read_trace(String.t(), keyword()) :: [map()]
  def read_trace(identifier, opts \\ []) when is_binary(identifier) do
    path =
      if String.ends_with?(identifier, ".jsonl") do
        identifier
      else
        trace_path(identifier, opts)
      end

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce([], fn line, acc ->
          case Jason.decode(line) do
            {:ok, decoded} when is_map(decoded) -> [decoded | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      {:error, _} ->
        []
    end
  end

  defp file_timestamp(path) do
    with {:ok, stat} <- File.stat(path),
         {:ok, naive} <- NaiveDateTime.from_erl(stat.mtime),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      datetime
    else
      _ -> DateTime.from_unix!(0)
    end
  end

  defp sanitize_value(%_{} = struct), do: struct |> Map.from_struct() |> sanitize_value()

  defp sanitize_value(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), sanitize_value(v)} end)

  defp sanitize_value(list) when is_list(list), do: Enum.map(list, &sanitize_value/1)

  defp sanitize_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize_value(value),
    do: inspect(value, pretty: false, limit: :infinity, printable_limit: 100_000)
end
