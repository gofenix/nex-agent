defmodule Nex.Agent.HotReload do
  @moduledoc false

  require Logger

  alias Nex.Agent.Tool.Registry

  @registry_poll_attempts 10
  @registry_poll_interval_ms 10

  @spec reload(String.t(), String.t()) :: map()
  def reload(path, content) do
    case detect_module(content) do
      {:ok, module_str, expected_module} ->
        compile_and_load(path, content, module_str, expected_module)

      {:error, reason} ->
        failure(nil, reason)
    end
  end

  @spec reload_expected(String.t(), String.t(), module()) :: map()
  def reload_expected(path, content, expected_module) do
    compile_and_load(path, content, module_name(expected_module), expected_module)
  end

  defp detect_module(content) do
    case Regex.run(~r/defmodule\s+([\w.]+)\s+do/, content) do
      [_, module_str] -> {:ok, module_str, Module.concat([module_str])}
      _ -> {:error, "Could not detect module name in file"}
    end
  end

  defp compile_and_load(_path, content, module_str, expected_module) do
    try do
      quoted = Code.string_to_quoted!(content)
      compiled = Code.compile_quoted(quoted)

      case pick_compiled_module(compiled, expected_module) do
        {:ok, {module, _binary}} ->
          success(module, maybe_hot_swap(module))

        {:error, reason} ->
          failure(module_str, reason)
      end
    rescue
      e -> failure(module_str, Exception.message(e))
    end
  end

  defp pick_compiled_module(compiled, expected_module) do
    case Enum.find(compiled, fn {module, _binary} -> module == expected_module end) do
      nil ->
        {:error, "compiled output did not include expected module #{inspect(expected_module)}"}

      module_binary ->
        {:ok, module_binary}
    end
  end

  defp maybe_hot_swap(module) do
    if Process.whereis(Registry) do
      Code.ensure_loaded(module)

      if function_exported?(module, :name, 0) and function_exported?(module, :execute, 2) do
        tool_name = module.name()

        case Registry.get(tool_name) do
          nil ->
            Registry.register(module)
            finalize_registry_swap(tool_name, module, :register)

          _existing ->
            Registry.hot_swap(tool_name, module)
            finalize_registry_swap(tool_name, module, :hot_swap)
        end
      else
        %{attempted: false, reason: :not_a_tool_module}
      end
    else
      %{attempted: false, reason: :registry_not_running}
    end
  end

  defp success(module, registry_swap) do
    %{
      reload_attempted: true,
      reload_succeeded: true,
      activation_scope: "next_invocation_uses_new_code",
      module: module_name(module),
      restart_required: false,
      reason: nil,
      registry_swap: registry_swap
    }
  end

  defp failure(module, reason) do
    %{
      reload_attempted: true,
      reload_succeeded: false,
      activation_scope: nil,
      module: module,
      restart_required: true,
      reason: failure_reason(reason),
      registry_swap: nil
    }
  end

  defp failure_reason(reason) when is_binary(reason) and byte_size(reason) > 0, do: reason
  defp failure_reason(reason) when is_binary(reason), do: "Hot reload failed"
  defp failure_reason(reason), do: inspect(reason)

  defp finalize_registry_swap(tool_name, module, operation) do
    swapped? = wait_for_registry_module(tool_name, module, @registry_poll_attempts)

    if swapped? do
      Logger.info("[HotReload] #{operation} completed for tool #{tool_name} in Registry")
    else
      Logger.warning("[HotReload] #{operation} timed out for tool #{tool_name} in Registry")
    end

    %{
      attempted: true,
      tool_name: tool_name,
      swapped?: swapped?,
      reason: if(swapped?, do: nil, else: :timeout),
      action: operation
    }
  end

  defp module_name(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp wait_for_registry_module(_tool_name, _module, 0), do: false

  defp wait_for_registry_module(tool_name, module, attempts_left) do
    if Registry.get(tool_name) == module do
      true
    else
      Process.sleep(@registry_poll_interval_ms)
      wait_for_registry_module(tool_name, module, attempts_left - 1)
    end
  end
end
