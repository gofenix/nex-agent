defmodule Nex.Agent.MCP.ServerManager do
  @moduledoc """
  MCP Server manager - dynamically start/stop MCP servers.

  ## Usage

      # Start an MCP server
      {:ok, server_id} = Nex.Agent.MCP.ServerManager.start("filesystem", [
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/test/data"]
      ])

      # Call a tool
      {:ok, result} = Nex.Agent.MCP.ServerManager.call_tool(server_id, "read_file", %{path: "/Users/test/data/file.txt"})

      # Stop a server
      :ok = Nex.Agent.MCP.ServerManager.stop(server_id)

      # List running servers
      servers = Nex.Agent.MCP.ServerManager.list()
  """

  use GenServer
  require Logger

  @name __MODULE__

  defstruct [:servers]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts ++ [name: @name])
  end

  @doc """
  Start an MCP server with the given config.

  ## Parameters

  * `name` - Server name (for identification)
  * `config` - Server configuration

  ## Examples

      {:ok, server_id} = Nex.Agent.MCP.ServerManager.start("my-server", [
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      ])
  """
  @spec start(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def start(name, config) do
    GenServer.call(@name, {:start, name, config})
  end

  @doc """
  Stop a running MCP server.
  """
  @spec stop(String.t()) :: :ok | {:error, String.t()}
  def stop(server_id) do
    GenServer.call(@name, {:stop, server_id})
  end

  @doc """
  Call a tool on an MCP server.
  """
  @spec call_tool(String.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def call_tool(server_id, tool_name, arguments) do
    GenServer.call(@name, {:call_tool, server_id, tool_name, arguments}, 30_000)
  end

  @doc """
  List all running servers.
  """
  @spec list() :: [map()]
  def list do
    GenServer.call(@name, :list)
  end

  @doc """
  Discover and auto-start available MCP servers.
  """
  @spec discover_and_start() :: {:ok, [String.t()]} | {:error, String.t()}
  def discover_and_start do
    servers = Nex.Agent.MCP.Discovery.scan()

    results =
      Enum.map(servers, fn config ->
        server_id = "#{config.name}-#{:rand.uniform(1000)}"

        case start(server_id,
               command: config.command,
               args: config.args || [],
               env: config.env || %{}
             ) do
          {:ok, _} -> {:ok, server_id}
          error -> error
        end
      end)

    successes = Enum.filter(results, &match?({:ok, _}, &1))
    {:ok, Enum.map(successes, fn {:ok, id} -> id end)}
  end

  # Server Callbacks

  @impl true
  def init([]) do
    {:ok, %{servers: %{}}}
  end

  @impl true
  def handle_call({:start, name, config}, _from, state) do
    server_id = "#{name}-#{:crypto.strong_rand_bytes(4) |> Base.encode16()}"

    case Nex.Agent.MCP.start_link(config) do
      {:ok, pid} ->
        # Initialize the connection
        case Nex.Agent.MCP.initialize(pid) do
          {:ok, _init_result} ->
            new_servers =
              Map.put(state.servers, server_id, %{
                pid: pid,
                name: name,
                config: config
              })

            {:reply, {:ok, server_id}, %{state | servers: new_servers}}

          {:error, reason} ->
            Nex.Agent.MCP.stop(pid)
            {:reply, {:error, "Failed to initialize: #{inspect(reason)}"}, state}
        end

      {:error, reason} ->
        {:reply, {:error, "Failed to start: #{inspect(reason)}"}, state}
    end
  end

  @impl true
  def handle_call({:stop, server_id}, _from, state) do
    case Map.get(state.servers, server_id) do
      nil ->
        {:reply, {:error, "Server not found"}, state}

      server ->
        Nex.Agent.MCP.stop(server.pid)
        new_servers = Map.delete(state.servers, server_id)
        {:reply, :ok, %{state | servers: new_servers}}
    end
  end

  @impl true
  def handle_call({:call_tool, server_id, tool_name, arguments}, _from, state) do
    case Map.get(state.servers, server_id) do
      nil ->
        {:reply, {:error, "Server not found"}, state}

      server ->
        result = Nex.Agent.MCP.call_tool(server.pid, tool_name, arguments)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    servers =
      Enum.map(state.servers, fn {id, config} ->
        %{
          id: id,
          name: config.name,
          config: config.config
        }
      end)

    {:reply, servers, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Stop all servers
    Enum.each(state.servers, fn {_, server} ->
      Nex.Agent.MCP.stop(server.pid)
    end)

    :ok
  end
end
