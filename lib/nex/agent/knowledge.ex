defmodule Nex.Agent.Knowledge do
  @moduledoc false

  alias Nex.Agent.{
    Audit,
    ContextDiagnostics,
    Memory,
    ProjectMemory,
    Skills,
    Workspace
  }

  @capture_file "captures.jsonl"
  @valid_sources ~w(chat_message web_page workspace_note)

  @spec capture(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def capture(attrs, opts \\ []) when is_map(attrs) do
    source = Map.get(attrs, "source") || Map.get(attrs, :source) || "chat_message"

    with :ok <- validate_source(source),
         {:ok, payload} <- normalize_capture_payload(source, attrs, opts) do
      capture =
        %{
          "id" => generate_id(),
          "source" => source,
          "title" => payload.title,
          "content" => payload.content,
          "summary" => summarize(payload.content),
          "url" => payload.url,
          "path" => payload.path,
          "project" => payload.project,
          "created_at" => now_iso()
        }

      Workspace.ensure!(opts)
      File.write!(capture_file(opts), Jason.encode!(capture) <> "\n", [:append])
      Audit.append("knowledge.capture", capture, opts)
      {:ok, capture}
    end
  end

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    source = Keyword.get(opts, :source)

    capture_file(opts)
    |> read_jsonl()
    |> Enum.filter(fn capture -> is_nil(source) or capture["source"] == source end)
    |> Enum.take(-limit)
    |> Enum.reverse()
  end

  @spec get(String.t(), keyword()) :: map() | nil
  def get(capture_id, opts \\ []) do
    capture_file(opts)
    |> read_jsonl()
    |> Enum.find(&(&1["id"] == capture_id))
  end

  @spec promote(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def promote(capture_id, target, opts \\ []) when is_binary(capture_id) and is_binary(target) do
    with %{} = capture <- get(capture_id, opts),
         {:ok, result} <- do_promote(capture, target, opts) do
      Audit.append("knowledge.promote", %{"capture_id" => capture_id, "target" => target}, opts)
      {:ok, result}
    else
      nil -> {:error, "Capture not found: #{capture_id}"}
      {:error, _} = error -> error
    end
  end

  @spec capture_file(keyword()) :: String.t()
  def capture_file(opts \\ []) do
    Path.join(Workspace.notes_dir(opts), @capture_file)
  end

  defp do_promote(capture, "memory", opts) do
    case Memory.apply_memory_write("append", "memory", capture["summary"] || capture["content"],
           workspace: Workspace.root(opts)
         ) do
      {:ok, _} -> {:ok, %{"target" => "memory", "capture_id" => capture["id"]}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_promote(capture, "user", opts) do
    current = Memory.read_user_profile(workspace: Workspace.root(opts))
    line = String.trim(capture["summary"] || capture["content"])

    case ContextDiagnostics.validate_write(:user, line, source: "USER.md") do
      :ok ->
        updated =
          if String.trim(current) == "" do
            "# User Profile\n\n" <> line <> "\n"
          else
            String.trim_trailing(current) <> "\n\n" <> line <> "\n"
          end

        Memory.write_user_profile(updated, workspace: Workspace.root(opts))
        {:ok, %{"target" => "user", "capture_id" => capture["id"]}}

      {:error, diagnostics} ->
        {:error, ContextDiagnostics.write_error_message(diagnostics)}
    end
  end

  defp do_promote(capture, "skill", opts) do
    name = capture["title"] || "captured-skill-#{capture["id"]}"
    description = capture["summary"] || summarize(capture["content"])
    content = capture["content"]

    case Skills.create(
           %{
             name: sanitize_skill_name(name),
             description: description,
             content: content
           },
           workspace: Workspace.root(opts)
         ) do
      {:ok, skill} ->
        {:ok,
         %{
           "target" => "skill",
           "capture_id" => capture["id"],
           "skill" => skill[:name] || skill["name"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_promote(capture, "project", opts) do
    project = capture["project"] || Keyword.get(opts, :project) || "personal"
    :ok = ProjectMemory.append_fact(project, capture["summary"] || capture["content"], opts)
    {:ok, %{"target" => "project", "capture_id" => capture["id"], "project" => project}}
  end

  defp do_promote(_capture, target, _opts) do
    {:error, "Unsupported target: #{target}"}
  end

  defp normalize_capture_payload("chat_message", attrs, _opts) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content)
    title = Map.get(attrs, "title") || Map.get(attrs, :title) || "Chat capture"

    if is_binary(content) and String.trim(content) != "" do
      {:ok,
       %{
         title: title,
         content: String.trim(content),
         url: nil,
         path: nil,
         project: Map.get(attrs, "project") || Map.get(attrs, :project)
       }}
    else
      {:error, "content is required for chat_message capture"}
    end
  end

  defp normalize_capture_payload("web_page", attrs, opts) do
    url = Map.get(attrs, "url") || Map.get(attrs, :url)
    title = Map.get(attrs, "title") || Map.get(attrs, :title) || url || "Web capture"
    fetch_fun = Keyword.get(opts, :fetch_fun, &fetch_web_page/1)

    if is_binary(url) and String.trim(url) != "" do
      case fetch_fun.(url) do
        {:ok, content} ->
          {:ok,
           %{
             title: title,
             content: String.trim(content),
             url: url,
             path: nil,
             project: Map.get(attrs, "project") || Map.get(attrs, :project)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "url is required for web_page capture"}
    end
  end

  defp normalize_capture_payload("workspace_note", attrs, opts) do
    path = Map.get(attrs, "path") || Map.get(attrs, :path)
    title = Map.get(attrs, "title") || Map.get(attrs, :title) || Path.basename(path || "note.md")

    with path when is_binary(path) <- path,
         {:ok, expanded} <- validate_workspace_note_path(path, opts),
         {:ok, content} <- File.read(expanded) do
      {:ok,
       %{
         title: title,
         content: String.trim(content),
         url: nil,
         path: expanded,
         project: Map.get(attrs, "project") || Map.get(attrs, :project)
       }}
    else
      nil -> {:error, "path is required for workspace_note capture"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_workspace_note_path(path, opts) do
    expanded = Path.expand(path, Workspace.root(opts))
    workspace = Workspace.root(opts) |> Path.expand()

    if expanded == workspace or String.starts_with?(expanded, workspace <> "/") do
      {:ok, expanded}
    else
      {:error, "workspace_note path must stay inside the workspace"}
    end
  end

  defp fetch_web_page(url) do
    case Nex.Agent.Tool.WebFetch.execute(%{"url" => url}, %{}) do
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, %{error: error}} -> {:error, error}
      {:ok, content} when is_binary(content) -> {:ok, content}
      {:ok, content} -> {:ok, inspect(content)}
      other -> {:error, inspect(other)}
    end
  end

  defp validate_source(source) when source in @valid_sources, do: :ok
  defp validate_source(source), do: {:error, "Unsupported source: #{source}"}

  defp sanitize_skill_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "captured_skill"
      value -> value
    end
  end

  defp summarize(content) do
    content
    |> String.trim()
    |> String.split(~r/\n+/, trim: true)
    |> List.first()
    |> to_string()
    |> String.slice(0, 200)
  end

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

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp generate_id do
    "cap_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
