defmodule Nex.Agent.Tool.FeishuTask do
  @moduledoc """
  Feishu Task tool - Manage tasks.

  Based on OpenClaw's feishu_task_* tools.

  Actions: task_create, task_list, task_get, task_update, task_complete, task_delete
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Feishu.Api

  def name, do: "feishu_task"
  def description, do: "Manage Feishu tasks."
  def category, do: :base

  def definition do
    %{
      name: "feishu_task",
      description: """
      飞书任务管理工具。

      ## Actions

      ### 任务
      - **task_create**: 创建任务
      - **task_list**: 列出任务
      - **task_get**: 获取任务详情
      - **task_update**: 更新任务
      - **task_complete**: 完成任务
      - **task_delete**: 删除任务

      ### 任务清单
      - **tasklist_create**: 创建任务清单
      - **tasklist_list**: 列出任务清单

      ### 子任务
      - **subtask_create**: 创建子任务
      - **subtask_update**: 更新子任务
      - **subtask_delete**: 删除子任务

      ### 评论
      - **comment_create**: 添加评论
      - **comment_list**: 列出评论
      - **comment_delete**: 删除评论
      """,
      parameters: %{
        type: "object",
        properties: %{
          "action" => %{
            type: "string",
            enum: [
              "task_create",
              "task_list",
              "task_get",
              "task_update",
              "task_complete",
              "task_delete",
              "tasklist_create",
              "tasklist_list",
              "subtask_create",
              "subtask_update",
              "subtask_delete",
              "comment_create",
              "comment_list",
              "comment_delete"
            ],
            description: "操作类型"
          },
          "task_id" => %{
            type: "string",
            description: "任务ID（task操作时使用）"
          },
          "tasklist_id" => %{
            type: "string",
            description: "任务清单ID（task操作时使用）"
          },
          "tasklist_guid" => %{
            type: "string",
            description: "任务清单GUID"
          },
          "summary" => %{
            type: "string",
            description: "任务标题"
          },
          "description" => %{
            type: "string",
            description: "任务描述"
          },
          "due_date" => %{
            type: "string",
            description: "截止日期（ISO 8601格式）"
          },
          "assignee_id" => %{
            type: "string",
            description: "负责人ID"
          },
          "parent_id" => %{
            type: "string",
            description: "父任务ID（子任务时使用）"
          },
          "completed" => %{
            type: "boolean",
            description: "是否完成"
          },
          "content" => %{
            type: "string",
            description: "评论内容"
          },
          "comment_id" => %{
            type: "string",
            description: "评论ID（comment操作时使用）"
          },
          "name" => %{
            type: "string",
            description: "名称（tasklist创建时使用）"
          },
          "page_size" => %{
            type: "integer",
            description: "分页大小"
          },
          "page_token" => %{
            type: "string",
            description: "分页标记"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(args, _ctx) do
    action = Map.get(args, "action")

    case action do
      "task_create" -> create_task(args)
      "task_list" -> list_tasks(args)
      "task_get" -> get_task(args)
      "task_update" -> update_task(args)
      "task_complete" -> complete_task(args)
      "task_delete" -> delete_task(args)
      "tasklist_create" -> create_tasklist(args)
      "tasklist_list" -> list_tasklists(args)
      "subtask_create" -> create_subtask(args)
      "subtask_update" -> update_subtask(args)
      "subtask_delete" -> delete_subtask(args)
      "comment_create" -> create_comment(args)
      "comment_list" -> list_comments(args)
      "comment_delete" -> delete_comment(args)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # Task operations
  defp create_task(args) do
    tasklist_guid = Map.get(args, "tasklist_guid", "flow:published:me")
    summary = Map.get(args, "summary", "新任务")
    description = Map.get(args, "description", "")
    due_date = Map.get(args, "due_date")
    assignee_id = Map.get(args, "assignee_id")

    assignee = if assignee_id, do: %{"member_id" => %{"open_id" => assignee_id}}, else: nil

    body =
      %{
        "task" => %{
          "summary" => summary,
          "description" => description
        }
      }
      |> maybe_add("due_date", due_date)
      |> maybe_add("assignee", assignee)

    case Api.post("/task/v1/tasklists/#{tasklist_guid}/tasks", body) do
      {:ok, data} ->
        task = Map.get(data, "task", %{})

        {:ok,
         %{
           task_id: Map.get(task, "id"),
           summary: summary,
           url: Map.get(task, "permalink")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp list_tasks(args) do
    tasklist_guid = Map.get(args, "tasklist_guid", "flow:published:me")
    page_size = Map.get(args, "page_size", 50)
    page_token = Map.get(args, "page_token")

    params = [{"page_size", page_size}] |> maybe_add_param("page_token", page_token)

    case Api.get("/task/v1/tasklists/#{tasklist_guid}/tasks", params: params) do
      {:ok, data} ->
        items = Map.get(data, "items", [])

        {:ok,
         %{
           tasks: Enum.map(items, &format_task/1),
           has_more: Map.get(data, "has_more", false),
           page_token: Map.get(data, "page_token")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp get_task(args) do
    task_id = Map.get(args, "task_id")
    if is_nil(task_id), do: {:error, "task_id is required"}, else: do_get_task(task_id)
  end

  defp do_get_task(task_id) do
    case Api.get("/task/v1/tasks/#{task_id}") do
      {:ok, data} -> {:ok, %{task: Map.get(data, "task", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp update_task(args) do
    task_id = Map.get(args, "task_id")
    summary = Map.get(args, "summary")
    description = Map.get(args, "description")
    due_date = Map.get(args, "due_date")
    completed = Map.get(args, "completed")

    if is_nil(task_id),
      do: {:error, "task_id is required"},
      else: do_update_task(task_id, summary, description, due_date, completed)
  end

  defp do_update_task(task_id, summary, description, due_date, completed) do
    body =
      %{"task" => %{}}
      |> maybe_add("summary", summary)
      |> maybe_add("description", description)
      |> maybe_add("due_date", due_date)
      |> maybe_add("completed", completed)

    case Api.patch("/task/v1/tasks/#{task_id}", body) do
      {:ok, data} -> {:ok, %{task: Map.get(data, "task", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp complete_task(args) do
    task_id = Map.get(args, "task_id")

    if is_nil(task_id),
      do: {:error, "task_id is required"},
      else: do_update_task(task_id, nil, nil, nil, true)
  end

  defp delete_task(args) do
    task_id = Map.get(args, "task_id")
    if is_nil(task_id), do: {:error, "task_id is required"}, else: do_delete_task(task_id)
  end

  defp do_delete_task(task_id) do
    case Api.delete("/task/v1/tasks/#{task_id}") do
      {:ok, _data} -> {:ok, %{success: true, task_id: task_id}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  # Tasklist operations
  defp create_tasklist(args) do
    name = Map.get(args, "name", "新任务清单")

    body = %{"tasklist" => %{"name" => name}}

    case Api.post("/task/v1/tasklists", body) do
      {:ok, data} ->
        tasklist = Map.get(data, "tasklist", %{})

        {:ok,
         %{
           tasklist_guid: Map.get(tasklist, "guid"),
           name: name
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp list_tasklists(_args) do
    case Api.get("/task/v1/tasklists") do
      {:ok, data} ->
        items = Map.get(data, "tasklists", [])

        {:ok,
         %{tasklists: Enum.map(items, &%{guid: Map.get(&1, "guid"), name: Map.get(&1, "name")})}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  # Subtask operations
  defp create_subtask(args) do
    parent_id = Map.get(args, "parent_id")
    summary = Map.get(args, "summary", "子任务")

    if is_nil(parent_id),
      do: {:error, "parent_id is required"},
      else: do_create_subtask(parent_id, summary)
  end

  defp do_create_subtask(parent_id, summary) do
    body = %{"task" => %{"summary" => summary}}

    case Api.post("/task/v1/tasks/#{parent_id}/subtasks", body) do
      {:ok, data} ->
        task = Map.get(data, "task", %{})
        {:ok, %{task_id: Map.get(task, "id"), summary: summary}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp update_subtask(args) do
    parent_id = Map.get(args, "parent_id")
    task_id = Map.get(args, "task_id")
    summary = Map.get(args, "summary")
    completed = Map.get(args, "completed")

    if is_nil(task_id),
      do: {:error, "task_id is required"},
      else: do_update_task(task_id, summary, nil, nil, completed)
  end

  defp delete_subtask(args) do
    parent_id = Map.get(args, "parent_id")
    task_id = Map.get(args, "task_id")

    if is_nil(task_id), do: {:error, "task_id is required"}, else: do_delete_task(task_id)
  end

  # Comment operations
  defp create_comment(args) do
    task_id = Map.get(args, "task_id")
    content = Map.get(args, "content", "")

    if is_nil(task_id) or content == "",
      do: {:error, "task_id and content are required"},
      else: do_create_comment(task_id, content)
  end

  defp do_create_comment(task_id, content) do
    comment_body = %{"content" => [%{"text" => content}]}
    body = %{"comment" => %{"body" => comment_body}}

    case Api.post("/task/v1/tasks/#{task_id}/comments", body) do
      {:ok, data} ->
        comment = Map.get(data, "comment", %{})

        {:ok,
         %{
           comment_id: Map.get(comment, "id"),
           content: content
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp list_comments(args) do
    task_id = Map.get(args, "task_id")
    if is_nil(task_id), do: {:error, "task_id is required"}, else: do_list_comments(task_id)
  end

  defp do_list_comments(task_id) do
    case Api.get("/task/v1/tasks/#{task_id}/comments") do
      {:ok, data} ->
        items = Map.get(data, "items", [])

        {:ok,
         %{
           comments:
             Enum.map(items, fn item ->
               content =
                 (get_in(item, ["body", "content"]) || [])
                 |> Enum.map_join("", fn x -> Map.get(x, "text") end)

               %{
                 id: Map.get(item, "id"),
                 content: content
               }
             end)
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp delete_comment(args) do
    task_id = Map.get(args, "task_id")
    comment_id = Map.get(args, "comment_id")

    if is_nil(task_id) or is_nil(comment_id),
      do: {:error, "task_id and comment_id are required"},
      else: do_delete_comment(task_id, comment_id)
  end

  defp do_delete_comment(task_id, comment_id) do
    case Api.delete("/task/v1/tasks/#{task_id}/comments/#{comment_id}") do
      {:ok, _data} -> {:ok, %{success: true, comment_id: comment_id}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp format_task(task) do
    %{
      id: Map.get(task, "id"),
      summary: Map.get(task, "summary"),
      description: Map.get(task, "description"),
      due_date: Map.get(task, "due_date"),
      completed: Map.get(task, "completed", false),
      permalink: Map.get(task, "permalink")
    }
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, to_string(value)}]

  defp format_error(%{code: code, message: msg}), do: "Feishu API error #{code}: #{msg}"
  defp format_error(%{code: code}), do: "Feishu API error #{code}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Error: #{inspect(reason)}"
end
