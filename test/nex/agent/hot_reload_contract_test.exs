defmodule Nex.Agent.HotReloadContractTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.Edit
  alias Nex.Agent.Tool.Registry
  alias Nex.Agent.Tool.Write

  setup do
    tmp_dir =
      Path.join(["/tmp", "nex_agent_hot_reload_contract_#{System.unique_integer([:positive])}"])

    custom_tools_dir = Path.join(tmp_dir, "tools")

    File.mkdir_p!(custom_tools_dir)

    original_custom_tools_path = Application.get_env(:nex_agent, :custom_tools_path)
    Application.put_env(:nex_agent, :custom_tools_path, custom_tools_dir)

    unless Process.whereis(Registry), do: {:ok, _pid} = Registry.start_link(name: Registry)
    :ok = Registry.reload()

    on_exit(fn ->
      if original_custom_tools_path == nil,
        do: Application.delete_env(:nex_agent, :custom_tools_path),
        else: Application.put_env(:nex_agent, :custom_tools_path, original_custom_tools_path)

      File.rm_rf!(tmp_dir)

      if Process.whereis(Registry) do
        :ok = Registry.reload()
      end
    end)

    %{tmp_dir: tmp_dir, custom_tools_dir: custom_tools_dir}
  end

  test "write success exposes a machine-readable hot reload contract", %{
    custom_tools_dir: custom_tools_dir
  } do
    path = Path.join([custom_tools_dir, "contract_write_tool", "tool.ex"])

    content = """
    defmodule Nex.Agent.Tool.Custom.ContractWriteTool do
      @behaviour Nex.Agent.Tool.Behaviour

      def name, do: "contract_write_tool"
      def description, do: "Contract write tool"
      def category, do: :base
      def definition, do: %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
      def execute(_args, _ctx), do: {:ok, "v1"}
    end
    """

    assert {:ok,
            %{
              path: ^path,
              hot_reload: %{
                reload_attempted: true,
                reload_succeeded: true,
                activation_scope: "next_invocation_uses_new_code",
                module: "Nex.Agent.Tool.Custom.ContractWriteTool",
                restart_required: false,
                reason: nil
              }
            }} =
             Write.execute(%{"path" => path, "content" => content}, %{})
  end

  test "edit failure exposes restart metadata with a concrete reason", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "broken_contract_module.ex")

    File.write!(path, """
    defmodule Nex.Agent.ContractBroken do
      def version, do: :ok
    end
    """)

    assert {:ok,
            %{
              path: ^path,
              hot_reload: %{
                reload_attempted: true,
                reload_succeeded: false,
                activation_scope: nil,
                module: nil,
                restart_required: true,
                reason: "Could not detect module name in file"
              }
            }} =
             Edit.execute(
               %{"path" => path, "search" => "defmodule", "replace" => "deffmodule"},
               %{}
             )
  end
end
