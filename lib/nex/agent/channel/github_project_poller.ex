defmodule Nex.Agent.Channel.GithubProjectPoller do
  @moduledoc false

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config, Workspace}
  alias Nex.Agent.Channel.Github

  @registry_file Path.join(["tasks", "github_items.json"])
  @default_gh_timeout_ms 120_000

  defstruct [
    :owner,
    :project_number,
    :poll_interval_ms,
    :workspace,
    :work_root,
    :required_label,
    :todo_status,
    :doing_status,
    :review_status,
    :done_status,
    :project_id,
    :status_field,
    :progress_field,
    :progress_field_id,
    :opencode_model,
    :run_fun,
    enabled: false,
    cleanup_after_merged: true
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, Config.load())
    github_project = Config.github_project(config)
    workspace = Keyword.get(opts, :workspace, Workspace.root()) |> Path.expand()

    owner = Keyword.get(opts, :owner, Config.github_project_owner(config))
    project_number = Keyword.get(opts, :project_number, Config.github_project_number(config))

    enabled =
      Keyword.get(opts, :enabled, Config.github_project_polling_enabled?(config)) and
        present?(owner) and is_integer(project_number)

    state = %__MODULE__{
      enabled: enabled,
      owner: owner,
      project_number: project_number,
      workspace: workspace,
      poll_interval_ms:
        Keyword.get(opts, :poll_interval_ms, Config.github_project_poll_interval_ms(config)),
      work_root:
        resolve_work_root(Keyword.get(opts, :work_root) || github_project["work_root"], workspace),
      cleanup_after_merged:
        Keyword.get(opts, :cleanup_after_merged, github_project["cleanup_after_merged"] != false),
      required_label: Keyword.get(opts, :required_label, github_project["required_label"]),
      todo_status: Keyword.get(opts, :todo_status, github_project["todo_status"]),
      doing_status: Keyword.get(opts, :doing_status, github_project["doing_status"]),
      review_status: Keyword.get(opts, :review_status, github_project["review_status"]),
      done_status: Keyword.get(opts, :done_status, github_project["done_status"]),
      project_id: Keyword.get(opts, :project_id, present(github_project["project_id"])),
      status_field: Keyword.get(opts, :status_field, github_project["status_field"]),
      progress_field: Keyword.get(opts, :progress_field, github_project["progress_field"]),
      progress_field_id:
        Keyword.get(opts, :progress_field_id, present(github_project["progress_field_id"])),
      opencode_model:
        Keyword.get(opts, :opencode_model, present(github_project["opencode_model"])),
      run_fun: Keyword.get(opts, :run_fun, &default_run/1)
    }

    if state.enabled do
      Logger.info(
        "[GithubProjectPoller] started owner=#{state.owner} project=#{state.project_number} interval_ms=#{state.poll_interval_ms}"
      )

      send(self(), :poll)
    else
      Logger.info("[GithubProjectPoller] disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{enabled: false} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    Logger.debug("[GithubProjectPoller] polling project items")

    case poll_once(state) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[GithubProjectPoller] poll failed: #{inspect(reason)}")
    end

    if state.poll_interval_ms != :manual do
      Process.send_after(self(), :poll, state.poll_interval_ms)
    end

    {:noreply, state}
  end

  def item_list_args(project_number, owner) do
    [
      "project",
      "item-list",
      to_string(project_number),
      "--owner",
      owner,
      "--format",
      "json",
      "--limit",
      "100"
    ]
  end

  def project_view_args(project_number, owner) do
    [
      "project",
      "view",
      to_string(project_number),
      "--owner",
      owner,
      "--format",
      "json"
    ]
  end

  def repo_clone_args(repo, work_dir), do: ["repo", "clone", repo, work_dir]

  def issue_view_args(repo, issue_number) do
    [
      "issue",
      "view",
      to_string(issue_number),
      "--repo",
      repo,
      "--json",
      "title,body,state,labels,url"
    ]
  end

  def issue_comments_args(repo, issue_number) do
    [
      "issue",
      "view",
      to_string(issue_number),
      "--repo",
      repo,
      "--comments",
      "--json",
      "comments"
    ]
  end

  def pr_view_args(repo, pr_url) do
    [
      "pr",
      "view",
      pr_url,
      "--repo",
      repo,
      "--json",
      "url,state,mergedAt,closed,number,headRefName"
    ]
  end

  def field_list_args(project_number, owner) do
    [
      "project",
      "field-list",
      to_string(project_number),
      "--owner",
      owner,
      "--format",
      "json"
    ]
  end

  def issue_close_args(repo, issue_number) do
    [
      "issue",
      "close",
      to_string(issue_number),
      "--repo",
      repo,
      "--comment",
      "PR merged; closing issue and marking Project item Done."
    ]
  end

  def issue_comment_args(repo, issue_number, body) do
    [
      "issue",
      "comment",
      to_string(issue_number),
      "--repo",
      repo,
      "--body",
      body
    ]
  end

  @doc false
  def run_command(command, args, timeout_ms) when is_binary(command) and is_list(args) do
    task =
      Task.async(fn ->
        System.cmd(command, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, %{exit_code: code, output: output, args: args}}
      nil -> {:error, :timeout}
    end
  end

  defp poll_once(state) do
    with {:ok, output} <- state.run_fun.(item_list_args(state.project_number, state.owner)),
         {:ok, items} <- decode_items(output) do
      registry = read_registry(state.workspace)
      normalized_items = items |> Enum.map(&normalize_item/1) |> Enum.reject(&is_nil/1)

      {next_registry, inbounds} =
        normalized_items
        |> Enum.reduce({registry, []}, fn item, {acc, inbounds} ->
          process_item(item, acc, inbounds, state)
        end)

      next_registry = ensure_registry_aliases(normalized_items, next_registry, state)
      write_registry(state.workspace, next_registry)

      inbounds
      |> Enum.reverse()
      |> Enum.each(&publish_inbound/1)

      next_registry =
        normalized_items
        |> poll_issue_comments(next_registry, state)
        |> poll_pr_lifecycle(normalized_items, state)

      write_registry(state.workspace, next_registry)

      :ok
    end
  end

  defp process_item(%{"status" => status, "id" => id} = item, registry, inbounds, state)
       when status == state.todo_status do
    cond do
      Map.has_key?(registry, id) ->
        {registry, inbounds}

      not has_required_label?(item, state.required_label) ->
        Logger.debug("[GithubProjectPoller] skip unlabeled item=#{id}")
        {registry, inbounds}

      true ->
        case prepare_pickup(item, state) do
          {:ok, prepared} ->
            entry = registry_entry(prepared, state)
            inbound = pickup_inbound(prepared, state)
            write_pickup_progress(prepared, state)
            {Map.put(registry, id, entry), [inbound | inbounds]}

          {:error, reason} ->
            Logger.warning(
              "[GithubProjectPoller] pickup prepare failed item=#{id} reason=#{inspect(reason)}"
            )

            {registry, inbounds}
        end
    end
  end

  defp process_item(_item, registry, inbounds, _state), do: {registry, inbounds}

  defp prepare_pickup(item, state) do
    work_dir = work_dir_for(state.work_root, item["id"], item["repo"])
    branch = branch_for(item["issue_number"], item["id"])

    with :ok <- ensure_work_dir(item["repo"], work_dir, state),
         {:ok, issue} <- fetch_issue(item, state) do
      {:ok,
       item
       |> Map.merge(issue)
       |> Map.put("work_dir", work_dir)
       |> Map.put("repo_path", work_dir)
       |> Map.put("branch", branch)}
    end
  end

  defp ensure_work_dir(repo, work_dir, state) do
    if File.dir?(work_dir) do
      :ok
    else
      File.mkdir_p!(Path.dirname(work_dir))

      case state.run_fun.(repo_clone_args(repo, work_dir)) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_issue(item, state) do
    case state.run_fun.(issue_view_args(item["repo"], item["issue_number"])) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, issue} when is_map(issue) ->
            {:ok,
             %{
               "issue_title" => issue["title"] || item["issue_title"],
               "issue_body" => issue["body"] || item["issue_body"] || "",
               "issue_url" => issue["url"] || item["issue_url"],
               "labels" => labels(issue)
             }}

          _ ->
            {:ok, %{}}
        end

      {:error, reason} ->
        Logger.warning(
          "[GithubProjectPoller] issue fetch failed repo=#{item["repo"]} issue=#{item["issue_number"]} reason=#{inspect(reason)}"
        )

        {:ok, %{}}
    end
  end

  defp registry_entry(item, state) do
    now = now_iso()

    %{
      "item_id" => item["id"],
      "status" => "doing",
      "claimed_at" => now,
      "last_check" => now,
      "issue_number" => item["issue_number"],
      "issue_url" => item["issue_url"],
      "repo" => item["repo"],
      "repo_path" => item["work_dir"],
      "work_dir" => item["work_dir"],
      "branch" => item["branch"],
      "pr_url" => nil,
      "opencode_model" => state.opencode_model,
      "cleanup_status" => nil
    }
  end

  defp pickup_inbound(item, state) do
    %{
      channel: "github",
      chat_id: state.owner,
      content: "Pick up Issue ##{item["issue_number"]}: #{item["issue_title"]}",
      workspace: state.workspace,
      metadata: %{
        _from_github_project: true,
        action: "pickup",
        item_id: item["id"],
        issue_url: item["issue_url"],
        issue_number: item["issue_number"],
        issue_title: item["issue_title"],
        issue_body: item["issue_body"] || "",
        repo: item["repo"],
        repo_path: item["work_dir"],
        work_dir: item["work_dir"],
        branch: item["branch"],
        pr_url: nil,
        opencode_model: state.opencode_model,
        project_owner: state.owner,
        project_number: state.project_number,
        todo_status: state.todo_status,
        doing_status: state.doing_status,
        review_status: state.review_status,
        done_status: state.done_status
      }
    }
  end

  defp write_pickup_progress(item, state) do
    with {:ok, project_id} <- project_id(state),
         {:ok, progress_field_id} <- progress_field_id(state) do
      args = [
        "project",
        "item-edit",
        "--id",
        item["id"],
        "--project-id",
        project_id,
        "--field-id",
        progress_field_id,
        "--text",
        "Picked up Issue ##{item["issue_number"]}: #{item["issue_title"]}"
      ]

      case state.run_fun.(args) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[GithubProjectPoller] pickup progress skipped item=#{item["id"]} reason=#{inspect(reason)}"
          )
      end
    else
      {:error, reason} ->
        Logger.warning(
          "[GithubProjectPoller] pickup progress skipped item=#{item["id"]} reason=#{inspect(reason)}"
        )
    end
  end

  defp normalize_item(%{"content" => %{"type" => "Issue"} = content, "id" => id} = item) do
    repo = content["repository"] || repo_from_url(item["repository"])
    issue_number = content["number"]

    if is_binary(repo) and is_integer(issue_number) do
      %{
        "id" => id,
        "status" => item["status"],
        "repo" => repo,
        "issue_number" => issue_number,
        "issue_url" => content["url"],
        "issue_title" => content["title"],
        "issue_body" => content["body"] || "",
        "labels" => Map.get(item, "labels", [])
      }
    end
  end

  defp normalize_item(_), do: nil

  defp repo_from_url("https://github.com/" <> repo), do: repo
  defp repo_from_url(_), do: nil

  defp decode_items(output) do
    case Jason.decode(output) do
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, items} when is_list(items) -> {:ok, items}
      _ -> {:error, :invalid_items_json}
    end
  end

  defp has_required_label?(_item, nil), do: true
  defp has_required_label?(_item, ""), do: true
  defp has_required_label?(item, label), do: label in Map.get(item, "labels", [])

  defp poll_issue_comments(items, registry, state) do
    Enum.reduce(items, registry, fn item, acc ->
      case registry_entry_for_item(acc, item) do
        nil -> acc
        entry -> poll_issue_comments_for_item(item, entry, acc, state)
      end
    end)
  end

  defp poll_issue_comments_for_item(item, entry, registry, state) do
    case state.run_fun.(issue_comments_args(item["repo"], item["issue_number"])) do
      {:ok, output} ->
        with {:ok, comments} <- decode_comments(output) do
          process_issue_comments(item, entry, comments, registry, state)
        else
          {:error, reason} ->
            Logger.warning(
              "[GithubProjectPoller] comment decode failed repo=#{item["repo"]} issue=#{item["issue_number"]} reason=#{inspect(reason)}"
            )

            registry
        end

      {:error, reason} ->
        Logger.warning(
          "[GithubProjectPoller] comment poll failed repo=#{item["repo"]} issue=#{item["issue_number"]} reason=#{inspect(reason)}"
        )

        registry
    end
  end

  defp process_issue_comments(item, entry, comments, registry, state) do
    checkpoint = comment_checkpoint(entry)

    {entry, registry} =
      comments
      |> Enum.map(&normalize_comment/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&(&1["created_at"] || ""))
      |> Enum.reduce({entry, registry}, fn comment, {entry_acc, registry_acc} ->
        entry_acc = advance_comment_checkpoint(entry_acc, comment, checkpoint)

        if new_comment?(comment, checkpoint) do
          next_entry =
            entry_acc
            |> Map.put("last_comment_id", comment["id"])
            |> Map.put("last_comment_url", comment["url"])
            |> Map.put("last_comment_body", comment["body"])

          next_registry = put_registry_aliases(registry_acc, item, next_entry, state)
          write_registry(state.workspace, next_registry)

          case ingest_issue_comment(item, entry_acc, comment, state) do
            :ok ->
              {next_entry, next_registry}

            {:ignore, _reason} ->
              {next_entry, next_registry}

            {:error, reason} ->
              Logger.warning(
                "[GithubProjectPoller] comment ingest failed repo=#{item["repo"]} issue=#{item["issue_number"]} comment=#{comment["id"]} reason=#{inspect(reason)}"
              )

              {next_entry, next_registry}
          end
        else
          {entry_acc, registry_acc}
        end
      end)

    put_registry_aliases(registry, item, entry, state)
  end

  defp ingest_issue_comment(item, entry, comment, state) do
    payload = %{
      "repository" => %{
        "full_name" => item["repo"],
        "html_url" => "https://github.com/#{item["repo"]}",
        "default_branch" => entry["default_branch"] || "main"
      },
      "issue" => %{
        "number" => item["issue_number"],
        "html_url" => item["issue_url"],
        "title" => item["issue_title"],
        "body" => item["issue_body"] || ""
      },
      "comment" => %{
        "id" => comment["id"],
        "body" => comment["body"],
        "html_url" => comment["url"],
        "user" => %{"login" => comment["author"]}
      },
      "sender" => %{"login" => comment["author"]}
    }

    Github.ingest_event(payload, event_type: "issue_comment", workspace: state.workspace)
  end

  defp decode_comments(output) do
    case Jason.decode(output) do
      {:ok, %{"comments" => comments}} when is_list(comments) -> {:ok, comments}
      {:ok, comments} when is_list(comments) -> {:ok, comments}
      _ -> {:error, :invalid_comments_json}
    end
  end

  defp normalize_comment(%{} = comment) do
    id =
      comment_id(comment["id"]) || comment_id(comment["node_id"]) ||
        comment_id(comment["databaseId"])

    body = present(comment["body"])
    url = present(comment["url"]) || present(comment["html_url"])
    created_at = present(comment["createdAt"]) || present(comment["created_at"])
    author = get_in(comment, ["author", "login"]) || get_in(comment, ["user", "login"])

    if id && body do
      %{
        "id" => id,
        "body" => body,
        "url" => url,
        "created_at" => created_at,
        "author" => author
      }
    end
  end

  defp normalize_comment(_), do: nil

  defp comment_id(value) when is_binary(value), do: present(value)
  defp comment_id(value) when is_integer(value), do: Integer.to_string(value)
  defp comment_id(_), do: nil

  defp comment_checkpoint(entry) do
    present(entry["last_comment_check"]) || present(entry["last_check"]) ||
      present(entry["claimed_at"])
  end

  defp advance_comment_checkpoint(entry, comment, checkpoint) do
    created_at = comment["created_at"]

    if created_at && (is_nil(checkpoint) or iso_after?(created_at, entry["last_comment_check"])) do
      Map.put(entry, "last_comment_check", created_at)
    else
      entry
    end
  end

  defp new_comment?(comment, nil), do: present(comment["created_at"]) != nil
  defp new_comment?(comment, checkpoint), do: iso_after?(comment["created_at"], checkpoint)

  defp iso_after?(nil, _checkpoint), do: false
  defp iso_after?(_created_at, nil), do: true

  defp iso_after?(created_at, checkpoint) do
    with {:ok, created, _} <- DateTime.from_iso8601(created_at),
         {:ok, checked, _} <- DateTime.from_iso8601(checkpoint) do
      DateTime.compare(created, checked) == :gt
    else
      _ -> created_at > checkpoint
    end
  end

  defp ensure_registry_aliases(items, registry, state) do
    Enum.reduce(items, registry, fn item, acc ->
      case registry_entry_for_item(acc, item) do
        nil -> acc
        entry -> put_registry_aliases(acc, item, entry, state)
      end
    end)
  end

  defp registry_entry_for_item(registry, item) do
    Map.get(registry, item["id"]) ||
      Map.get(registry, issue_key(item)) ||
      if(item["issue_url"], do: Map.get(registry, item["issue_url"]), else: nil)
  end

  defp put_registry_aliases(registry, item, entry, state) do
    entry =
      entry
      |> Map.put_new("item_id", item["id"])
      |> Map.put_new("repo", item["repo"])
      |> Map.put_new("issue_number", item["issue_number"])
      |> Map.put_new("issue_url", item["issue_url"])
      |> Map.put_new("opencode_model", state.opencode_model)

    registry
    |> Map.put(item["id"], entry)
    |> Map.put(issue_key(item), entry)
    |> maybe_put_issue_url(item, entry)
  end

  defp maybe_put_issue_url(registry, %{"issue_url" => issue_url}, entry)
       when is_binary(issue_url) do
    Map.put(registry, issue_url, entry)
  end

  defp maybe_put_issue_url(registry, _item, _entry), do: registry

  defp issue_key(item), do: "#{item["repo"]}##{item["issue_number"]}"

  defp poll_pr_lifecycle(registry, items, state) do
    Enum.reduce(items, registry, fn item, acc ->
      case registry_entry_for_item(acc, item) do
        nil -> acc
        entry -> poll_pr_lifecycle_for_item(item, entry, acc, state)
      end
    end)
  end

  defp poll_pr_lifecycle_for_item(item, entry, registry, state) do
    pr_url = present(entry["pr_url"])

    cond do
      is_nil(pr_url) ->
        registry

      entry["cleanup_status"] == "deleted" and entry["status"] in ["done", "todo"] ->
        registry

      true ->
        case state.run_fun.(pr_view_args(item["repo"], pr_url)) do
          {:ok, output} ->
            case decode_pr(output) do
              {:ok, pr} -> handle_pr_lifecycle(item, entry, pr, registry, state)
              {:error, reason} -> log_pr_lifecycle_skip(item, reason, registry)
            end

          {:error, reason} ->
            log_pr_lifecycle_skip(item, reason, registry)
        end
    end
  end

  defp handle_pr_lifecycle(item, entry, pr, registry, state) do
    cond do
      pr_merged?(pr) ->
        issue_close_result = close_issue(item, state)
        project_status_result = set_project_status(item, state.done_status, state)
        {entry, cleanup_status} = cleanup_entry_work_dir(entry, state)
        synced? = issue_close_result == :ok and project_status_result == :ok

        entry =
          entry
          |> Map.merge(%{
            "status" => if(synced?, do: "done", else: entry["status"] || "review"),
            "pr_state" => "merged",
            "merged_at" => pr["mergedAt"],
            "cleanup_status" => cleanup_status,
            "issue_close_status" => sync_status(issue_close_result),
            "project_status_sync" => sync_status(project_status_result),
            "last_check" => now_iso()
          })

        put_registry_aliases(registry, item, entry, state)

      pr_closed_unmerged?(pr) ->
        issue_comment_result = comment_closed_unmerged(item, state)
        project_status_result = set_project_status(item, state.todo_status, state)
        {entry, cleanup_status} = cleanup_entry_work_dir(entry, state)
        synced? = issue_comment_result == :ok and project_status_result == :ok

        entry =
          entry
          |> Map.merge(%{
            "status" => if(synced?, do: "todo", else: entry["status"] || "review"),
            "pr_url" => if(synced?, do: nil, else: entry["pr_url"]),
            "pr_state" => "closed_unmerged",
            "cleanup_status" => cleanup_status,
            "issue_comment_status" => sync_status(issue_comment_result),
            "project_status_sync" => sync_status(project_status_result),
            "last_check" => now_iso()
          })

        put_registry_aliases(registry, item, entry, state)

      true ->
        entry =
          entry
          |> Map.put("pr_state", String.downcase(to_string(pr["state"] || "open")))
          |> Map.put("last_pr_check", now_iso())

        put_registry_aliases(registry, item, entry, state)
    end
  end

  defp decode_pr(output) do
    case Jason.decode(output) do
      {:ok, pr} when is_map(pr) -> {:ok, pr}
      _ -> {:error, :invalid_pr_json}
    end
  end

  defp pr_merged?(pr) do
    String.upcase(to_string(pr["state"] || "")) == "MERGED" or present(pr["mergedAt"]) != nil
  end

  defp pr_closed_unmerged?(pr) do
    String.upcase(to_string(pr["state"] || "")) == "CLOSED" and is_nil(present(pr["mergedAt"]))
  end

  defp close_issue(item, state) do
    case state.run_fun.(issue_close_args(item["repo"], item["issue_number"])) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[GithubProjectPoller] issue close failed repo=#{item["repo"]} issue=#{item["issue_number"]} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp comment_closed_unmerged(item, state) do
    body = "PR closed without merge; returning this Project item to Todo."

    case state.run_fun.(issue_comment_args(item["repo"], item["issue_number"], body)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[GithubProjectPoller] closed PR comment failed repo=#{item["repo"]} issue=#{item["issue_number"]} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp set_project_status(item, status, state) do
    with {:ok, project_id} <- project_id(state),
         {:ok, fields_output} <-
           state.run_fun.(field_list_args(state.project_number, state.owner)),
         {:ok, status_field_id, option_id} <-
           status_option(fields_output, state.status_field, status) do
      args = [
        "project",
        "item-edit",
        "--id",
        item["id"],
        "--project-id",
        project_id,
        "--field-id",
        status_field_id,
        "--single-select-option-id",
        option_id
      ]

      case state.run_fun.(args) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[GithubProjectPoller] project status update failed item=#{item["id"]} status=#{status} reason=#{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.warning(
          "[GithubProjectPoller] project status lookup failed item=#{item["id"]} status=#{status} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp sync_status(:ok), do: "ok"
  defp sync_status({:error, _reason}), do: "error"
  defp sync_status(_), do: "error"

  defp status_option(output, status_field_name, status_name) do
    with {:ok, %{"fields" => fields}} when is_list(fields) <- Jason.decode(output),
         %{"id" => field_id, "options" => options} when is_list(options) <-
           Enum.find(fields, &(&1["name"] == status_field_name)),
         %{"id" => option_id} <- Enum.find(options, &(&1["name"] == status_name)) do
      {:ok, field_id, option_id}
    else
      _ -> {:error, :missing_status_option}
    end
  end

  defp project_id(state) do
    case present(state.project_id) do
      nil ->
        with {:ok, output} <- state.run_fun.(project_view_args(state.project_number, state.owner)),
             {:ok, %{"id" => id}} when is_binary(id) and id != "" <- Jason.decode(output) do
          {:ok, id}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :missing_project_id}
        end

      project_id ->
        {:ok, project_id}
    end
  end

  defp progress_field_id(state) do
    case present(state.progress_field_id) do
      nil ->
        with {:ok, output} <- state.run_fun.(field_list_args(state.project_number, state.owner)),
             {:ok, field_id} <- field_id(output, state.progress_field) do
          {:ok, field_id}
        end

      progress_field_id ->
        {:ok, progress_field_id}
    end
  end

  defp field_id(output, field_name) do
    with {:ok, %{"fields" => fields}} when is_list(fields) <- Jason.decode(output),
         %{"id" => field_id} when is_binary(field_id) <-
           Enum.find(fields, &(&1["name"] == field_name)) do
      {:ok, field_id}
    else
      _ -> {:error, :missing_field_id}
    end
  end

  defp cleanup_entry_work_dir(entry, state) do
    work_dir = present(entry["work_dir"])

    cond do
      state.cleanup_after_merged == false ->
        {entry, "retained"}

      is_nil(work_dir) ->
        {entry, "missing"}

      not safe_work_dir?(work_dir, state) ->
        {entry, "unsafe_path"}

      not File.exists?(work_dir) ->
        {entry, "missing"}

      true ->
        case File.rm_rf(work_dir) do
          {:ok, _} -> {entry, "deleted"}
          {:error, _path, reason} -> {Map.put(entry, "cleanup_error", inspect(reason)), "error"}
        end
    end
  end

  defp safe_work_dir?(work_dir, state) do
    work_root = Path.expand(state.work_root)
    expanded = Path.expand(work_dir)
    expanded != work_root and String.starts_with?(expanded, work_root <> "/")
  end

  defp log_pr_lifecycle_skip(item, reason, registry) do
    Logger.warning(
      "[GithubProjectPoller] PR lifecycle check failed repo=#{item["repo"]} issue=#{item["issue_number"]} reason=#{inspect(reason)}"
    )

    registry
  end

  defp labels(%{"labels" => labels}) when is_list(labels) do
    Enum.map(labels, fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp labels(_), do: []

  defp work_dir_for(work_root, item_id, repo) do
    Path.join([work_root, "items", safe_segment(item_id), String.replace(repo, "/", "__")])
  end

  defp resolve_work_root(nil, workspace), do: Path.join(workspace, "github")
  defp resolve_work_root("", workspace), do: Path.join(workspace, "github")

  defp resolve_work_root(work_root, workspace) when is_binary(work_root) do
    cond do
      Path.type(work_root) == :absolute ->
        Path.expand(work_root)

      String.starts_with?(work_root, "workspace/") ->
        work_root
        |> String.replace_prefix("workspace/", "")
        |> then(&Path.join(workspace, &1))

      work_root == "workspace" ->
        workspace

      true ->
        Path.join(workspace, work_root)
    end
  end

  defp branch_for(issue_number, item_id) do
    "codex/github-issue-#{issue_number}-#{String.slice(safe_segment(item_id), 0, 12)}"
  end

  defp safe_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end

  defp publish_inbound(inbound) do
    Logger.info(
      "[GithubProjectPoller] inbound action=#{inbound.metadata.action} item=#{inbound.metadata.item_id}"
    )

    Bus.publish(:inbound, inbound)
  end

  defp read_registry(workspace) do
    path = registry_path(workspace)

    with true <- File.exists?(path),
         {:ok, decoded} <- File.read!(path) |> Jason.decode(),
         true <- is_map(decoded) do
      decoded
    else
      _ -> %{}
    end
  end

  defp write_registry(workspace, registry) do
    path = registry_path(workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(registry, pretty: true))
  end

  defp registry_path(workspace), do: Path.join(workspace, @registry_file)

  defp default_run(args) do
    run_command("gh", args, @default_gh_timeout_ms)
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil
  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  defp now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
