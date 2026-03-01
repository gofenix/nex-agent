defmodule Nex.Agent.Session do
  alias Nex.Agent.Entry

  defstruct [
    :id,
    :project_id,
    :path,
    entries: [],
    current_entry_id: nil
  ]

  @session_dir "~/.nex/agent/sessions"

  def create(project_id, cwd \\ nil) do
    _working_dir = cwd || File.cwd!()
    session_id = generate_session_id()
    project_dir = sanitize_project_id(project_id)

    dir = Path.join([Path.expand(@session_dir), project_dir, session_id])

    case File.mkdir_p(dir) do
      :ok ->
        session = %__MODULE__{
          id: session_id,
          project_id: project_id,
          path: dir,
          entries: [],
          current_entry_id: nil
        }

        session_entry = Entry.new_session(project_id)
        session = add_entry(session, session_entry)

        {:ok, session}

      error ->
        error
    end
  end

  def load(session_id, project_id) do
    project_dir = sanitize_project_id(project_id)
    dir = Path.join([Path.expand(@session_dir), project_dir, session_id])
    file = entries_file_path(dir)

    if File.exists?(file) do
      case File.read(file) do
        {:ok, content} ->
          entries =
            content
            |> String.split("\n", trim: true)
            |> Enum.map(&Entry.from_json/1)
            |> Enum.filter(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, e} -> e end)

          current_entry_id =
            if length(entries) > 0 do
              List.last(entries).id
            end

          {:ok,
           %__MODULE__{
             id: session_id,
             project_id: project_id,
             path: dir,
             entries: entries,
             current_entry_id: current_entry_id
           }}

        error ->
          error
      end
    else
      {:error, :session_not_found}
    end
  end

  def add_entry(%__MODULE__{} = session, %Entry{} = entry) do
    file = entries_file_path(session.path)
    line = Entry.to_json(entry) <> "\n"

    File.write(file, line, [:append])

    %{session | entries: session.entries ++ [entry], current_entry_id: entry.id}
  end

  def fork(%__MODULE__{} = session) do
    {:ok, forked} = create(session.project_id <> "-fork", Path.dirname(session.path))

    forked =
      Enum.reduce(session.entries, forked, fn entry, acc ->
        add_entry(acc, entry)
      end)

    {:ok, forked}
  end

  def navigate(%__MODULE__{} = session, entry_id) do
    case Enum.find(session.entries, &(&1.id == entry_id)) do
      nil ->
        {:error, :entry_not_found}

      _entry ->
        {:ok, %{session | current_entry_id: entry_id}}
    end
  end

  def current_path(%__MODULE__{} = session) do
    entries_map = Map.new(session.entries, fn e -> {e.id, e} end)

    path = []
    current_id = session.current_entry_id

    loop(path, current_id, entries_map, 0)
  end

  defp loop(acc, nil, _map, _), do: Enum.reverse(acc)
  defp loop(acc, _id, _map, 1000), do: Enum.reverse(acc)

  defp loop(acc, current_id, map, n) do
    case Map.get(map, current_id) do
      nil ->
        Enum.reverse(acc)

      entry ->
        loop([entry | acc], entry.parent_id, map, n + 1)
    end
  end

  def branches(%__MODULE__{} = session) do
    children_ids =
      session.entries
      |> Enum.map(& &1.parent_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    session.entries
    |> Enum.filter(fn e -> not MapSet.member?(children_ids, e.id) end)
    |> Enum.map(fn e -> {e.id, e.timestamp} end)
  end

  def current_messages(%__MODULE__{} = session) do
    current_path(session)
    |> Enum.filter(fn e -> e.type == :message end)
    |> Enum.map(& &1.message)
    |> Enum.reject(&is_nil/1)
  end

  def get_latest_model(%__MODULE__{} = session) do
    path = current_path(session)

    path
    |> Enum.reverse()
    |> Enum.find(fn e -> e.type == :model_change end)
    |> case do
      nil -> nil
      e -> {e.data.provider, e.data.model}
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower)
  end

  defp sanitize_project_id(project_id) do
    project_id |> String.replace(~r/[^\w-]/, "_")
  end

  defp entries_file_path(session_dir) do
    preferred = Path.join(session_dir, "_.jsonl")
    legacy = Path.join(session_dir, "_ .jsonl")

    cond do
      File.exists?(preferred) -> preferred
      File.exists?(legacy) -> legacy
      true -> preferred
    end
  end
end
