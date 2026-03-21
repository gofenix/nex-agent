defmodule Nex.Agent.ProjectMemory do
  @moduledoc false

  alias Nex.Agent.Workspace

  @project_file "PROJECT.md"
  @runs_file "executor_runs.jsonl"

  @spec detect_project(String.t() | nil) :: String.t() | nil
  def detect_project(nil), do: nil

  def detect_project(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)

    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true, cd: cwd) do
      {path, 0} ->
        path
        |> String.trim()
        |> Path.basename()

      _ ->
        cwd
        |> Path.basename()
        |> blank_to_nil()
    end
  rescue
    _ -> cwd |> Path.basename() |> blank_to_nil()
  end

  @spec read(String.t(), keyword()) :: String.t()
  def read(project, opts \\ []) when is_binary(project) do
    case File.read(project_file(project, opts)) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  @spec append_fact(String.t(), String.t(), keyword()) :: :ok
  def append_fact(project, content, opts \\ []) when is_binary(project) and is_binary(content) do
    project_dir = project_dir(project, opts)
    File.mkdir_p!(project_dir)

    existing = read(project, opts)

    updated =
      cond do
        String.trim(content) == "" ->
          existing

        existing == "" ->
          String.trim(content) <> "\n"

        String.contains?(existing, String.trim(content)) ->
          existing

        true ->
          String.trim_trailing(existing) <> "\n\n- " <> String.trim(content) <> "\n"
      end

    File.write!(project_file(project, opts), updated)
    :ok
  end

  @spec append_run(String.t(), map(), keyword()) :: :ok
  def append_run(project, run, opts \\ []) when is_binary(project) and is_map(run) do
    project_dir = project_dir(project, opts)
    File.mkdir_p!(project_dir)
    File.write!(runs_file(project, opts), Jason.encode!(stringify_keys(run)) <> "\n", [:append])
    :ok
  end

  @spec recent_runs(String.t(), keyword()) :: [map()]
  def recent_runs(project, opts \\ []) when is_binary(project) do
    limit = Keyword.get(opts, :limit, 10)

    runs_file(project, opts)
    |> read_jsonl()
    |> Enum.take(-limit)
    |> Enum.reverse()
  end

  @spec project_file(String.t(), keyword()) :: String.t()
  def project_file(project, opts \\ []) do
    Path.join(project_dir(project, opts), @project_file)
  end

  @spec project_dir(String.t(), keyword()) :: String.t()
  def project_dir(project, opts \\ []) do
    Path.join(Workspace.projects_dir(opts), slug(project))
  end

  defp runs_file(project, opts), do: Path.join(project_dir(project, opts), @runs_file)

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

  defp slug(project) do
    project
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/u, "-")
    |> String.trim("-")
    |> blank_to_nil()
    |> Kernel.||("default-project")
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp stringify_keys(map) do
    Enum.into(map, %{}, fn {key, value} ->
      value =
        cond do
          is_map(value) -> stringify_keys(value)
          is_list(value) -> Enum.map(value, &stringify_list_value/1)
          true -> value
        end

      {to_string(key), value}
    end)
  end

  defp stringify_list_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_list_value(value), do: value
end
