defmodule Nex.Agent.MCP.Discovery do
  @moduledoc """
  MCP Server auto-discovery module.

  Scans PATH for mcp-server-* executables and returns a list of available servers.

  Supports configuration override via ~/.nex/agent/mcp.json

  ## Usage

      # Auto-discover from PATH
      servers = Nex.Agent.MCP.Discovery.scan()
      
      # Or use cached discovery
      servers = Nex.Agent.MCP.Discovery.list()
  """

  @config_path "~/.nex/agent/mcp.json"

  @doc """
  Scan PATH for mcp-server-* executables.

  Returns a list of server configs:
  ```elixir
  [
    %{name: "filesystem", command: "mcp-server-filesystem", args: []},
    %{name: "github", command: "/opt/homebrew/bin/mcp-server-github", args: ["--token", "xxx"]}
  ]
  ```
  """
  @spec scan() :: list(map())
  def scan do
    config_servers = load_config()
    discovered_servers = discover_from_path()

    # Config servers take precedence over auto-discovered
    merge_servers(discovered_servers, config_servers)
  end

  @doc """
  List cached servers (if caching is implemented).
  Currently just calls scan/0.
  """
  @spec list() :: list(map())
  def list, do: scan()

  # Private functions

  defp load_config do
    config_path = Path.expand(@config_path)

    if File.exists?(config_path) do
      case File.read(config_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{"servers" => servers}} when is_map(servers) ->
              servers
              |> Enum.map(fn {name, config} ->
                Map.put(config, "name", name)
              end)

            {:ok, _} ->
              []

            {:error, reason} ->
              IO.puts(:stderr, "Warning: Failed to parse MCP config: #{inspect(reason)}")
              []
          end

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  defp discover_from_path do
    path = System.get_env("PATH", "")

    path
    |> String.split(":")
    |> Enum.flat_map(&scan_directory/1)
    |> Enum.uniq_by(& &1.name)
  end

  defp scan_directory(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "mcp-server-"))
        |> Enum.map(fn filename ->
          command = Path.join(dir, filename)

          name =
            filename
            |> String.replace_prefix("mcp-server-", "")
            |> String.replace_suffix(".exe", "")

          %{
            name: name,
            command: command,
            args: [],
            source: :auto_discovered
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp merge_servers(auto_discovered, configured) do
    # Build a map of auto-discovered by name
    auto_map = Enum.into(auto_discovered, %{}, &{&1.name, &1})

    # Override with configured
    configured_map =
      Enum.into(configured, %{}, fn config ->
        name = config["name"] || "unknown"

        merged =
          case auto_map[name] do
            nil ->
              # Not auto-discovered, use config
              %{
                name: name,
                command: config["command"] || name,
                args: config["args"] || [],
                env: config["env"] || %{},
                source: :configured
              }

            auto ->
              # Merge with auto-discovered
              %{
                name: name,
                command: config["command"] || auto.command,
                args: config["args"] || auto.args,
                env: config["env"] || %{},
                source: :merged
              }
          end

        {name, merged}
      end)

    # Return merged list, with configured taking precedence
    Map.values(configured_map) ++
      (auto_discovered |> Enum.reject(&Map.has_key?(configured_map, &1.name)))
  end
end
