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
    Nex.Agent.Tool.ListDir,
    Nex.Agent.Tool.Bash,
    Nex.Agent.Tool.WebSearch,
    Nex.Agent.Tool.WebFetch,
    Nex.Agent.Tool.Message,
    Nex.Agent.Tool.SkillCreate,
    Nex.Agent.Tool.SoulUpdate,
    Nex.Agent.Tool.SpawnTask,
    Nex.Agent.Tool.SkillList,
    Nex.Agent.Tool.Evolve,
    Nex.Agent.Tool.Reflect,
    Nex.Agent.Tool.Cron
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
      (@default_tools ++ discover_tool_modules())
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn module, acc ->
        case safe_tool_name(module) do
          {:ok, name} ->
            Map.put(acc, name, module)

          :error ->
            Logger.warning("[Registry] Failed to register tool: #{inspect(module)}")
            acc
        end
      end)

    Logger.info("[Registry] Started with #{map_size(tools)} tools: #{inspect(Map.keys(tools) |> Enum.sort())}")
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

  @impl true
  def handle_cast({:unregister, name}, %{tools: tools} = state) do
    {:noreply, %{state | tools: Map.delete(tools, name)}}
  end

  @impl true
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

  @impl true
  def handle_call({:definitions, filter}, _from, %{tools: tools} = state) do
    defs =
      tools
      |> filter_tools(filter)
      |> Enum.map(fn {name, module} ->
        def_map = module.definition() |> normalize_definition()

        %{
          "name" => get_def_name(def_map) || name,
          "description" => get_def_description(def_map),
          "input_schema" => get_def_params(def_map)
        }
      end)

    {:reply, defs, state}
  end

  @impl true
  def handle_call({:execute, name, args, ctx}, from, %{tools: tools} = state) do
    case Map.get(tools, name) do
      nil ->
        {:reply, {:error, "Unknown tool: #{name}. [Analyze the error and try a different approach.]"}, state}

      module ->
        Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
          result =
            try do
              module.execute(args, ctx)
            rescue
              e ->
                {:error, "Tool #{name} crashed: #{Exception.message(e)}. [Analyze the error and try a different approach.]"}
            catch
              :exit, {:timeout, _} ->
                {:error, "Tool #{name} timed out. [Analyze the error and try a different approach.]"}
              kind, reason ->
                {:error, "Tool #{name} failed: #{kind} #{inspect(reason)}. [Analyze the error and try a different approach.]"}
            end

          GenServer.reply(from, result)
        end)

        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:list, _from, %{tools: tools} = state) do
    {:reply, Map.keys(tools), state}
  end

  @impl true
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

  # Scan tool directory for modules not in @default_tools.
  # This picks up tools created via evolve that survive restarts.
  defp discover_tool_modules do
    tool_dir = Path.join([File.cwd!(), "lib", "nex", "agent", "tool"])

    if File.dir?(tool_dir) do
      tool_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.flat_map(fn file ->
        # Extract actual module name from source file instead of guessing from filename
        filepath = Path.join(tool_dir, file)

        case extract_module_name(filepath) do
          {:ok, module} when module not in @default_tools ->
            # Try loading compiled beam first; if missing, compile the source file
            case Code.ensure_loaded(module) do
              {:module, _} -> :ok
              {:error, _} ->
                try do
                  Code.compile_file(filepath)
                rescue
                  e -> Logger.warning("[Registry] Failed to compile #{filepath}: #{Exception.message(e)}")
                end
            end

            if function_exported?(module, :name, 0) do
              Logger.info("[Registry] Discovered evolved tool: #{inspect(module)}")
              [module]
            else
              []
            end

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  # Parse `defmodule Nex.Agent.Tool.Foo do` from source file.
  defp extract_module_name(filepath) do
    case File.open(filepath, [:read]) do
      {:ok, device} ->
        result = scan_for_module(device)
        File.close(device)
        result

      _ ->
        :error
    end
  end

  defp scan_for_module(device) do
    case IO.read(device, :line) do
      :eof ->
        :error

      {:error, _} ->
        :error

      line ->
        case Regex.run(~r/defmodule\s+([\w.]+)/, line) do
          [_, module_str] -> {:ok, Module.concat([module_str])}
          nil -> scan_for_module(device)
        end
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

  # Unwrap OpenAI-style nested definition: %{type: "function", function: %{name, description, parameters}}
  defp normalize_definition(%{function: inner}) when is_map(inner), do: inner
  defp normalize_definition(%{"function" => inner}) when is_map(inner), do: inner
  defp normalize_definition(def_map), do: def_map

  @cron_tools ~w(bash read message web_search web_fetch)

  defp filter_tools(tools, :all), do: tools

  defp filter_tools(tools, :cron) do
    Enum.filter(tools, fn {name, _module} -> name in @cron_tools end)
  end

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
