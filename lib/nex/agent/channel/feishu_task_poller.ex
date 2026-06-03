defmodule Nex.Agent.Channel.FeishuTaskPoller do
  @moduledoc false

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.FeishuTask

  @state_file Path.join(["tasks", "poll_state.json"])

  defstruct [
    :enabled,
    :workspace,
    :poll_interval_ms,
    :run_fun,
    :bot_open_id
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec default_list_args() :: [String.t()]
  def default_list_args do
    ["task", "+get-my-tasks", "--as", "user", "--format", "json", "--page-all"]
  end

  @spec completed_list_args() :: [String.t()]
  def completed_list_args do
    default_list_args() ++ ["--complete"]
  end

  @spec comments_args(String.t()) :: [String.t()]
  def comments_args(task_id) do
    [
      "api",
      "GET",
      "/open-apis/task/v2/comments",
      "--params",
      Jason.encode!(%{
        resource_id: task_id,
        resource_type: "task",
        sort_order: "asc",
        page_size: 50
      }),
      "--format",
      "json"
    ]
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, Config.load())
    feishu = Config.feishu(config)

    state = %__MODULE__{
      enabled:
        Keyword.get(opts, :enabled, Map.get(feishu, "task_polling_enabled", false) == true),
      workspace: Keyword.get(opts, :workspace, task_workspace()),
      poll_interval_ms:
        Keyword.get(opts, :poll_interval_ms, Config.feishu_task_poll_interval_ms(config)),
      run_fun: Keyword.get(opts, :run_fun, &default_run/1),
      bot_open_id: Keyword.get(opts, :bot_open_id, Config.feishu_bot_open_id(config))
    }

    if state.enabled and state.poll_interval_ms != :manual do
      Logger.info("[FeishuTaskPoller] started interval_ms=#{state.poll_interval_ms}")
      send(self(), :poll)
    else
      Logger.info("[FeishuTaskPoller] disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{enabled: false} = state), do: {:noreply, state}

  @impl true
  def handle_info(:poll, state) do
    Logger.debug("[FeishuTaskPoller] polling tasks")

    case poll_once(state) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[FeishuTaskPoller] poll failed: #{inspect(reason)}")
    end

    if state.poll_interval_ms != :manual do
      schedule_poll(state.poll_interval_ms)
    end

    {:noreply, state}
  end

  defp poll_once(state) do
    with {:ok, open_output} <- state.run_fun.(default_list_args()),
         {:ok, completed_output} <- state.run_fun.(completed_list_args()),
         {:ok, open_tasks} <- decode_tasks(open_output),
         {:ok, completed_tasks} <- decode_tasks(completed_output) do
      tasks = open_tasks ++ completed_tasks
      previous = read_state(state.workspace)
      previous_tasks = Map.get(previous, "tasks", %{})
      previous_comments = Map.get(previous, "comments", %{})
      baseline? = Map.get(previous, "initialized") != true and previous_tasks == %{}

      {next_tasks, status_inbounds} =
        tasks
        |> Enum.map(&normalize_task/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce({previous_tasks, []}, fn task, {acc, inbounds} ->
          id = task["id"]
          current = task_state(task)
          previous_task = Map.get(previous_tasks, id)
          action = if baseline?, do: nil, else: action_for(previous_task, current)
          acc = Map.put(acc, id, current)

          case action do
            nil ->
              {acc, inbounds}

            action ->
              case task_to_inbound(task, action) do
                {:ok, inbound} -> {acc, [inbound | inbounds]}
                :ignore -> {acc, inbounds}
              end
          end
        end)

      {next_comments, comment_inbounds} = poll_comments(tasks, previous_comments, state)

      write_state(state.workspace, %{
        "initialized" => true,
        "tasks" => next_tasks,
        "comments" => next_comments
      })

      (status_inbounds ++ comment_inbounds)
      |> Enum.reverse()
      |> Enum.each(&publish_inbound(&1, state))

      :ok
    end
  end

  defp decode_tasks(output) when is_binary(output) do
    with {:ok, decoded} <- Jason.decode(output) do
      cond do
        is_list(decoded) -> {:ok, decoded}
        is_list(decoded["items"]) -> {:ok, decoded["items"]}
        is_list(get_in(decoded, ["data", "items"])) -> {:ok, get_in(decoded, ["data", "items"])}
        is_list(get_in(decoded, ["data", "tasks"])) -> {:ok, get_in(decoded, ["data", "tasks"])}
        true -> {:ok, []}
      end
    end
  end

  defp decode_comments(output) when is_binary(output) do
    with {:ok, decoded} <- Jason.decode(output) do
      cond do
        is_list(decoded) -> {:ok, decoded}
        is_list(decoded["items"]) -> {:ok, decoded["items"]}
        is_list(get_in(decoded, ["data", "items"])) -> {:ok, get_in(decoded, ["data", "items"])}
        true -> {:ok, []}
      end
    end
  end

  defp normalize_task(task) when is_map(task) do
    id = first_string(task, ["guid", "task_id", "id", "task_guid"])

    if blank?(id) do
      nil
    else
      %{
        "id" => id,
        "title" => first_string(task, ["summary", "title", "name"]) || "",
        "description" => first_string(task, ["description", "desc"]) || "",
        "status" => normalize_status(first_string(task, ["status", "task_status"])),
        "updated_at" => first_string(task, ["updated_at", "update_time", "modified_at"]) || "",
        "creator_id" =>
          first_string(task, ["creator_id", "owner_id", "operator_user_id", "user_id"]) ||
            nested_id(task, "creator") ||
            ""
      }
    end
  end

  defp normalize_task(_), do: nil

  defp task_state(task) do
    %{
      "status" => task["status"],
      "signature" =>
        Enum.join(
          [task["id"], task["status"], task["updated_at"], task["title"], task["description"]],
          "|"
        )
    }
  end

  defp action_for(nil, %{"status" => status}) when status in ["open", "in_progress"],
    do: "created"

  defp action_for(%{"status" => "completed"}, %{"status" => status})
       when status in ["open", "in_progress"],
       do: "rerun"

  defp action_for(_previous, _current), do: nil

  defp poll_comments(tasks, previous_comments, state) do
    tasks
    |> Enum.map(&normalize_task/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce({previous_comments, []}, fn task, {comments_acc, inbounds} ->
      task_id = task["id"]
      seen_for_task = Map.get(previous_comments, task_id, %{})

      case state.run_fun.(comments_args(task_id)) do
        {:ok, output} ->
          {:ok, comments} = decode_comments(output)

          {next_seen, task_inbounds} =
            comments
            |> Enum.map(&normalize_comment/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.reduce({seen_for_task, []}, fn comment, {seen_acc, acc} ->
              comment_id = comment["id"]
              seen? = Map.has_key?(seen_for_task, comment_id)
              seen_acc = Map.put(seen_acc, comment_id, comment["signature"])

              if seen? or not rerun_comment?(comment) do
                {seen_acc, acc}
              else
                case task_comment_to_inbound(task, comment) do
                  {:ok, inbound} -> {seen_acc, [inbound | acc]}
                  :ignore -> {seen_acc, acc}
                end
              end
            end)

          {Map.put(comments_acc, task_id, next_seen), task_inbounds ++ inbounds}

        {:error, reason} ->
          Logger.warning(
            "[FeishuTaskPoller] comment poll failed task=#{task_id} reason=#{inspect(reason)}"
          )

          {comments_acc, inbounds}
      end
    end)
  end

  defp task_to_inbound(task, "created") do
    %{
      "header" => %{
        "event_type" => "task.task.updated_v1",
        "operator_user_id" => task["creator_id"]
      },
      "event" => %{
        "task_id" => task["id"],
        "title" => task["title"],
        "description" => task["description"],
        "creator_id" => task["creator_id"]
      }
    }
    |> FeishuTask.normalize()
  end

  defp task_to_inbound(task, "rerun") do
    %{
      "header" => %{
        "event_type" => "task.task.updated_v1",
        "operator_user_id" => task["creator_id"]
      },
      "event" => %{
        "task_id" => task["id"],
        "title" => task["title"],
        "description" => task["description"],
        "creator_id" => task["creator_id"],
        "changes" => %{"status" => %{"old" => "completed", "new" => "in_progress"}}
      }
    }
    |> FeishuTask.normalize()
  end

  defp task_comment_to_inbound(task, comment) do
    operator_id = present(comment["operator_user_id"]) || present(task["creator_id"])
    creator_id = present(task["creator_id"]) || operator_id

    %{
      "header" => %{
        "event_type" => "task.task.comment.updated_v1",
        "operator_user_id" => operator_id
      },
      "event" => %{
        "task_id" => task["id"],
        "title" => task["title"],
        "description" => task["description"],
        "creator_id" => creator_id,
        "comment" => %{"content" => comment["content"]}
      }
    }
    |> FeishuTask.normalize()
  end

  defp publish_inbound(
         %{metadata: %{task_id: task_id, task_action: action, operator_user_id: operator_id}} =
           inbound,
         state
       ) do
    if FeishuTask.dup?(state.bot_open_id, operator_id, task_id, action, state.workspace) do
      Logger.debug("[FeishuTaskPoller] dedup task=#{task_id} action=#{action}")
    else
      FeishuTask.record_dedup(task_id, action, state.workspace)
      Logger.info("[FeishuTaskPoller] Task inbound id=#{task_id} action=#{action}")
      Bus.publish(:inbound, inbound)
    end
  end

  defp read_state(workspace) do
    path = state_path(workspace)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{} = state} -> state
          _ -> %{"tasks" => %{}}
        end

      _ ->
        %{"tasks" => %{}}
    end
  end

  defp write_state(workspace, state) do
    path = state_path(workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(state, pretty: true))
  end

  defp state_path(workspace), do: Path.join(workspace, @state_file)

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
        value when is_binary(value) and value != "" -> value
        value when is_integer(value) -> Integer.to_string(value)
        _ -> nil
      end
    end)
  end

  defp normalize_comment(comment) when is_map(comment) do
    id = first_string(comment, ["comment_id", "guid", "id"])
    content = comment_content(comment)

    if blank?(id) do
      nil
    else
      %{
        "id" => id,
        "content" => content || "",
        "operator_user_id" =>
          first_string(comment, ["operator_user_id", "creator_id", "user_id", "open_id"]) ||
            nested_id(comment, "creator"),
        "signature" =>
          Enum.join(
            [id, content || "", first_string(comment, ["created_at", "create_time"]) || ""],
            "|"
          )
      }
    end
  end

  defp normalize_comment(_), do: nil

  defp comment_content(comment) do
    case Map.get(comment, "content") || Map.get(comment, :content) do
      value when is_binary(value) ->
        value

      %{} = content ->
        first_string(content, ["text", "plain_text", "content"])

      _ ->
        first_string(comment, ["text", "plain_text"])
    end
  end

  defp nested_id(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      %{} = nested -> first_string(nested, ["id", "open_id", "user_id"])
      _ -> nil
    end
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_), do: nil

  defp rerun_comment?(%{"content" => content}) when is_binary(content) do
    String.contains?(String.downcase(content), "/rerun")
  end

  defp rerun_comment?(_), do: false

  defp normalize_status(status) when status in ["completed", "done"], do: "completed"
  defp normalize_status(status) when status in ["in_progress", "open", "todo"], do: "in_progress"
  defp normalize_status(_), do: "open"

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp default_run(args) do
    case System.cmd("lark-cli", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{status: status, output: output}}
    end
  end

  defp task_workspace do
    Application.get_env(:nex_agent, :workspace_path) ||
      Path.expand("~/.nex/agent/workspace")
  end

  defp schedule_poll(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :poll, interval_ms)
  end
end
