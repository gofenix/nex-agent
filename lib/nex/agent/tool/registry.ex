defmodule Nex.Agent.Tool.Registry do
  @moduledoc """
  Tool Registry - dynamic registration/unregistration/hot-swap of tool modules.
  Central place to manage all agent tools.
  """

  use GenServer
  require Logger

  @default_tools [
    Nex.Agent.Tool.Read,
    Nex.Agent.Tool.Write,
    Nex.Agent.Tool.Edit,
    Nex.Agent.Tool.Bash,
    Nex.Agent.Tool.WebSearch,
    Nex.Agent.Tool.WebFetch,
    Nex.Agent.Tool.Message,
    Nex.Agent.Tool.SkillCreate,
    Nex.Agent.Tool.SoulUpdate,
    Nex.Agent.Tool.SpawnTask,
    Nex.Agent.Tool.SkillList,
    Nex.Agent.Tool.SkillSearch,
    Nex.Agent.Tool.SkillInstall,
    Nex.Agent.Tool.Evolve,
    Nex.Agent.Tool.Reflect
  ]

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register a tool module."
  def register(module) do
    GenServer.cast(__MODULE__, {:register, module})
  end

  @doc "Unregister a tool by name."
  def unregister(name) do
    GenServer.cast(__MODULE__, {:unregister, name})
  end

  @doc "Atomic hot-swap: unregister old + register new."
  def hot_swap(name, new_module) do
    GenServer.cast(__MODULE__, {:hot_swap, name, new_module})
  end

  @doc """
  Get tool definitions for LLM.
  Filter: :all | :base | :subagent
  """
  def definitions(filter \\ :all) do
    GenServer.call(__MODULE__, {:definitions, filter})
  end

  @doc "Execute a tool by name."
  def execute(name, args, ctx \\ %{}) do
    GenServer.call(__MODULE__, {:execute, name, args, ctx}, 120_000)
  end

  @doc "List all registered tool names."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Get module for a tool name."
  def get(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  # Server

  @impl true
  def init(_opts) do
    tools =
      @default_tools
      |> Enum.reduce(%{}, fn module, acc ->
        case safe_tool_name(module) do
          {:ok, name} ->
            Map.put(acc, name, module)

          :error ->
            Logger.warning("[Registry] Failed to register default tool: #{inspect(module)}")
            acc
        end
      end)

    Logger.info("[Registry] Started with #{map_size(tools)} tools: #{inspect(Map.keys(tools))}")
    {:ok, %{tools: tools}}
  end

  @impl true
  def handle_cast({:register, module}, %{tools: tools} = state) do
    case safe_tool_name(module) do
      {:ok, name} ->
        {:noreply, %{state | tools: Map.put(tools, name, module)}}

      :error ->
        Logger.warning("[Registry] Failed to register module: #{inspect(module)}")
        {:noreply, state}
    end
  end

  def handle_cast({:unregister, name}, %{tools: tools} = state) do
    {:noreply, %{state | tools: Map.delete(tools, name)}}
  end

  def handle_cast({:hot_swap, name, new_module}, %{tools: tools} = state) do
    case safe_tool_name(new_module) do
      {:ok, new_name} ->
        tools = tools |> Map.delete(name) |> Map.put(new_name, new_module)
        Logger.info("[Registry] Hot-swapped #{name} -> #{new_name}")
        {:noreply, %{state | tools: tools}}

      :error ->
        Logger.warning("[Registry] Hot-swap failed for #{name}: module doesn't implement callbacks")
        {:noreply, state}
    end
  end

  def handle_call({:definitions, filter}, _from, %{tools: tools} = state) do
    defs =
      tools
      |> filter_tools(filter)
      |> Enum.map(fn {_name, module} ->
        def_map = module.definition()
        tool_name = get_def_name(def_map)
        params = get_def_params(def_map)

        %{
          "name" => tool_name,
          "description" => get_def_description(def_map),
          "input_schema" => params
        }
      end)

    {:reply, defs, state}
  end

  def handle_call({:execute, name, args, ctx}, _from, %{tools: tools} = state) do
    case Map.get(tools, name) do
      nil ->
        {:reply, {:error, "Unknown tool: #{name}. [Analyze the error and try a different approach.]"}, state}

      module ->
        result =
          try do
            module.execute(args, ctx)
          rescue
            e ->
              {:error, "Tool #{name} crashed: #{Exception.message(e)}. [Analyze the error and try a different approach.]"}
          end

        {:reply, result, state}
    end
  end

  def handle_call(:list, _from, %{tools: tools} = state) do
    {:reply, Map.keys(tools), state}
  end

  def handle_call({:get, name}, _from, %{tools: tools} = state) do
    {:reply, Map.get(tools, name), state}
  end

  # Helpers

  defp safe_tool_name(module) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, :name, 0) ->
        {:ok, module.name()}

      function_exported?(module, :definition, 0) ->
        def_map = module.definition()
        name = get_def_name(def_map)
        if name, do: {:ok, name}, else: :error

      true ->
        :error
    end
  end

  defp get_def_name(%{name: n}), do: n
  defp get_def_name(%{"name" => n}), do: n
  defp get_def_name(_), do: nil

  defp get_def_description(%{description: d}), do: d
  defp get_def_description(%{"description" => d}), do: d
  defp get_def_description(_), do: ""

  defp get_def_params(%{parameters: p}), do: p
  defp get_def_params(%{"parameters" => p}), do: p
  defp get_def_params(%{input_schema: p}), do: p
  defp get_def_params(%{"input_schema" => p}), do: p
  defp get_def_params(_), do: %{"type" => "object", "properties" => %{}}

  defp filter_tools(tools, :all), do: tools

  defp filter_tools(tools, :base) do
    Enum.filter(tools, fn {_name, module} ->
      if function_exported?(module, :category, 0) do
        module.category() == :base
      else
        true
      end
    end)
  end

  defp filter_tools(tools, :subagent) do
    filter_tools(tools, :base)
  end
end
