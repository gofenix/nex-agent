defmodule Nex.Agent.Channel.Github do
  @moduledoc false

  alias Nex.Agent.{Bus, Workspace}

  @processed_file Path.join(["tasks", "github_events.json"])
  @registry_file Path.join(["tasks", "github_items.json"])
  @wake_words ["@nex", "@next"]

  @spec ingest_event(map(), keyword()) :: :ok | {:ignore, atom()} | {:error, atom()}
  def ingest_event(payload, opts \\ []) when is_map(payload) do
    event_type = Keyword.get(opts, :event_type) || System.get_env("GITHUB_EVENT_NAME") || "github"
    workspace = Keyword.get(opts, :workspace, Workspace.root()) |> Path.expand()
    wake_words = Keyword.get(opts, :wake_words, @wake_words)
    publish_fun = Keyword.get(opts, :publish_fun, &Bus.publish/2)

    with {:ok, body} <- comment_body(payload),
         true <- mentions_wake_word?(body, wake_words) || {:ignore, :missing_wake_word},
         {:ok, event_id} <- event_id(payload),
         true <- not processed?(workspace, event_id) || {:ignore, :duplicate},
         {:ok, inbound} <- build_inbound(payload, body, event_type, workspace) do
      mark_processed(workspace, event_id)
      publish_fun.(:inbound, inbound)
      :ok
    end
  end

  defp comment_body(payload) do
    case get_in(payload, ["comment", "body"]) do
      body when is_binary(body) -> {:ok, body}
      _ -> {:error, :missing_comment_body}
    end
  end

  defp event_id(payload) do
    case get_in(payload, ["comment", "id"]) do
      id when is_integer(id) -> {:ok, "comment:#{id}"}
      id when is_binary(id) and id != "" -> {:ok, "comment:#{id}"}
      _ -> {:error, :missing_comment_id}
    end
  end

  defp mentions_wake_word?(body, wake_words) when is_binary(body) do
    normalized = String.downcase(body)

    Enum.any?(wake_words, fn wake_word ->
      String.contains?(normalized, String.downcase(wake_word))
    end)
  end

  defp build_inbound(payload, body, event_type, workspace) do
    repo = get_in(payload, ["repository", "full_name"])
    issue_number = get_in(payload, ["issue", "number"])

    if is_binary(repo) and issue_number do
      registry =
        registry_entry(workspace, repo, issue_number, get_in(payload, ["issue", "html_url"]))

      registry_pr_url =
        present(registry["pr_url"]) ||
          present(get_in(payload, ["issue", "pull_request", "html_url"]))

      metadata = %{
        _from_github: true,
        event_type: event_type,
        repo: repo,
        repo_url: get_in(payload, ["repository", "html_url"]),
        default_branch: get_in(payload, ["repository", "default_branch"]),
        issue_number: issue_number,
        issue_url: get_in(payload, ["issue", "html_url"]),
        issue_title: get_in(payload, ["issue", "title"]),
        issue_body: get_in(payload, ["issue", "body"]) || "",
        pr_url: registry_pr_url,
        work_dir: present(registry["work_dir"]),
        repo_path: present(registry["repo_path"]) || present(registry["work_dir"]),
        branch: present(registry["branch"]),
        opencode_model: present(registry["opencode_model"]),
        item_id: present(registry["item_id"]),
        comment_id: get_in(payload, ["comment", "id"]),
        comment_body: body,
        comment_url: get_in(payload, ["comment", "html_url"]),
        comment_author:
          get_in(payload, ["comment", "user", "login"]) || get_in(payload, ["sender", "login"]),
        registry: registry
      }

      {:ok,
       %{
         channel: "github",
         chat_id: "#{repo}##{issue_number}",
         content: body,
         workspace: workspace,
         metadata: metadata
       }}
    else
      {:error, :missing_repo_or_issue}
    end
  end

  defp processed?(workspace, event_id) do
    workspace
    |> processed_path()
    |> read_json()
    |> Map.has_key?(event_id)
  end

  defp mark_processed(workspace, event_id) do
    path = processed_path(workspace)
    events = read_json(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Map.put(events, event_id, timestamp()), pretty: true))
  end

  defp processed_path(workspace), do: Path.join(workspace, @processed_file)

  defp registry_entry(workspace, repo, issue_number, issue_url) do
    registry = workspace |> registry_path() |> read_json()

    Map.get(registry, "#{repo}##{issue_number}") ||
      if(is_binary(issue_url), do: Map.get(registry, issue_url), else: nil) ||
      %{}
  end

  defp registry_path(workspace), do: Path.join(workspace, @registry_file)

  defp read_json(path) do
    with true <- File.exists?(path),
         {:ok, decoded} <- File.read!(path) |> Jason.decode(),
         true <- is_map(decoded) do
      decoded
    else
      _ -> %{}
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil
end
