defmodule Nex.Agent.Workspace do
  @moduledoc false

  alias Nex.Agent.Config

  @default_root Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")

  @known_dirs ~w(memory skills tools notes tasks projects executors audit skill_runtime)

  @spec default_root() :: String.t()
  def default_root, do: @default_root

  @spec root(keyword()) :: String.t()
  def root(opts \\ []) do
    Keyword.get(opts, :workspace) ||
      Application.get_env(:nex_agent, :workspace_path) ||
      inferred_root_from_config()
  end

  @spec dir(String.t(), keyword()) :: String.t()
  def dir(name, opts \\ []) when is_binary(name) do
    Path.join(root(opts), name)
  end

  @spec memory_dir(keyword()) :: String.t()
  def memory_dir(opts \\ []), do: dir("memory", opts)

  @spec skills_dir(keyword()) :: String.t()
  def skills_dir(opts \\ []), do: dir("skills", opts)

  @spec tools_dir(keyword()) :: String.t()
  def tools_dir(opts \\ []), do: dir("tools", opts)

  @spec notes_dir(keyword()) :: String.t()
  def notes_dir(opts \\ []), do: dir("notes", opts)

  @spec tasks_dir(keyword()) :: String.t()
  def tasks_dir(opts \\ []), do: dir("tasks", opts)

  @spec projects_dir(keyword()) :: String.t()
  def projects_dir(opts \\ []), do: dir("projects", opts)

  @spec executors_dir(keyword()) :: String.t()
  def executors_dir(opts \\ []), do: dir("executors", opts)

  @spec audit_dir(keyword()) :: String.t()
  def audit_dir(opts \\ []), do: dir("audit", opts)

  @spec skill_runtime_dir(keyword()) :: String.t()
  def skill_runtime_dir(opts \\ []), do: dir("skill_runtime", opts)

  @spec ensure!(keyword()) :: :ok
  def ensure!(opts \\ []) do
    workspace = root(opts)
    File.mkdir_p!(workspace)

    Enum.each(@known_dirs, fn name ->
      File.mkdir_p!(dir(name, opts))
    end)

    :ok
  end

  @spec known_dirs() :: [String.t()]
  def known_dirs, do: @known_dirs

  defp inferred_root_from_config do
    config_path =
      Application.get_env(:nex_agent, :config_path, Config.default_config_path()) |> Path.expand()

    default_config_path = Config.default_config_path() |> Path.expand()

    if config_path != default_config_path do
      Path.expand(Path.join(Path.dirname(config_path), "workspace"))
    else
      @default_root
    end
  end
end
