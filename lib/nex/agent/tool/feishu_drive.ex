defmodule Nex.Agent.Tool.FeishuDrive do
  @moduledoc """
  Feishu Drive tool - Manage files in Feishu Drive.

  Based on OpenClaw's feishu_drive_file tool.

  Actions: list, get_meta, copy, move, delete, upload, download
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Feishu.Api

  def name, do: "feishu_drive"
  def description, do: "Manage files in Feishu Drive."
  def category, do: :base

  def definition do
    %{
      name: "feishu_drive",
      description: """
      飞书云空间文件管理工具。

      ## Actions

      - **list**: 列出文件夹下的文件。不传folder_token则列出根目录
      - **get_meta**: 批量获取文件元信息
      - **copy**: 复制文件
      - **move**: 移动文件
      - **delete**: 删除文件
      - **upload**: 上传文件（base64）
      - **download**: 下载文件（返回base64）

      ## 注意事项

      - copy/move/delete 需要 file_token 和 type 参数
      - upload 支持 file_content_base64 或 file_path
      - download 可选 output_path 保存到本地
      """,
      parameters: %{
        type: "object",
        properties: %{
          "action" => %{
            type: "string",
            enum: ["list", "get_meta", "copy", "move", "delete", "upload", "download"],
            description: "操作类型"
          },
          "folder_token" => %{
            type: "string",
            description: "文件夹token（list时使用，不传则根目录）"
          },
          "file_token" => %{
            type: "string",
            description: "文件token（copy/move/delete/download时必填）"
          },
          "type" => %{
            type: "string",
            enum: ["doc", "docx", "sheet", "bitable", "file", "folder", "mindnote", "slides"],
            description: "文件类型（copy/move/delete时必填）"
          },
          "name" => %{
            type: "string",
            description: "目标文件名（copy时使用）"
          },
          "request_docs" => %{
            type: "array",
            description: "文档列表（get_meta时使用），格式：[{doc_token: '...', doc_type: 'sheet'}]",
            items: %{
              type: "object",
              properties: %{
                "doc_token" => %{type: "string"},
                "doc_type" => %{type: "string"}
              }
            }
          },
          "file_content_base64" => %{
            type: "string",
            description: "文件内容的Base64编码（upload时使用）"
          },
          "file_name" => %{
            type: "string",
            description: "文件名（upload时使用）"
          },
          "file_size" => %{
            type: "integer",
            description: "文件大小（upload时使用）"
          },
          "page_size" => %{
            type: "integer",
            description: "分页大小（list时使用，默认200）",
            minimum: 1,
            maximum: 200
          },
          "page_token" => %{
            type: "string",
            description: "分页标记（list时使用）"
          },
          "order_by" => %{
            type: "string",
            enum: ["EditedTime", "CreatedTime"],
            description: "排序方式（list时使用）"
          },
          "direction" => %{
            type: "string",
            enum: ["ASC", "DESC"],
            description: "排序方向（list时使用）"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(args, _ctx) do
    action = Map.get(args, "action")

    case action do
      "list" -> list_files(args)
      "get_meta" -> get_meta(args)
      "copy" -> copy_file(args)
      "move" -> move_file(args)
      "delete" -> delete_file(args)
      "upload" -> upload_file(args)
      "download" -> download_file(args)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # List files in folder
  defp list_files(args) do
    folder_token = Map.get(args, "folder_token", "")
    page_size = Map.get(args, "page_size", 200)
    page_token = Map.get(args, "page_token")
    order_by = Map.get(args, "order_by")
    direction = Map.get(args, "direction")

    params =
      [
        {"folder_token", folder_token},
        {"page_size", page_size}
      ]
      |> maybe_add_param("page_token", page_token)
      |> maybe_add_param("order_by", order_by)
      |> maybe_add_param("direction", direction)

    case Api.get("/drive/v1/files", params: params) do
      {:ok, data} ->
        files = Map.get(data, "files", [])

        {:ok,
         %{
           files: Enum.map(files, &format_file_info/1),
           has_more: Map.get(data, "has_more", false),
           page_token: Map.get(data, "page_token")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  # Get file metadata
  defp get_meta(args) do
    request_docs = Map.get(args, "request_docs", [])

    if request_docs == [] do
      {:error, "request_docs is required for get_meta action"}
    else
      case Api.post("/drive/v1/metas/batch_query", %{"request_docs" => request_docs}) do
        {:ok, data} ->
          {:ok, %{metas: Map.get(data, "metas", [])}}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  # Copy file
  defp copy_file(args) do
    file_token = Map.get(args, "file_token")
    name = Map.get(args, "name")
    type = Map.get(args, "type")
    folder_token = Map.get(args, "folder_token")

    if is_nil(file_token) or is_nil(name) or is_nil(type) do
      {:error, "file_token, name, and type are required for copy action"}
    else
      body =
        %{"name" => name, "type" => type}
        |> maybe_add_body("folder_token", folder_token)

      case Api.post("/drive/v1/files/#{file_token}/copy", body) do
        {:ok, data} ->
          {:ok, %{file: Map.get(data, "file")}}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  # Move file
  defp move_file(args) do
    file_token = Map.get(args, "file_token")
    type = Map.get(args, "type")
    folder_token = Map.get(args, "folder_token")

    if is_nil(file_token) or is_nil(type) or is_nil(folder_token) do
      {:error, "file_token, type, and folder_token are required for move action"}
    else
      body = %{"type" => type, "folder_token" => folder_token}

      case Api.post("/drive/v1/files/#{file_token}/move", body) do
        {:ok, data} ->
          {:ok,
           %{
             success: true,
             task_id: Map.get(data, "task_id"),
             file_token: file_token
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  # Delete file
  defp delete_file(args) do
    file_token = Map.get(args, "file_token")
    type = Map.get(args, "type")

    if is_nil(file_token) or is_nil(type) do
      {:error, "file_token and type are required for delete action"}
    else
      case Api.delete("/drive/v1/files/#{file_token}?type=#{type}") do
        {:ok, data} ->
          {:ok,
           %{
             success: true,
             task_id: Map.get(data, "task_id"),
             file_token: file_token
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  # Upload file
  defp upload_file(args) do
    file_name = Map.get(args, "file_name")
    file_content_base64 = Map.get(args, "file_content_base64")
    file_size = Map.get(args, "file_size")
    parent_node = Map.get(args, "parent_node", "")

    if is_nil(file_name) or is_nil(file_content_base64) or is_nil(file_size) do
      {:error, "file_name, file_content_base64, and file_size are required for upload action"}
    else
      file_data = Base.decode64!(file_content_base64)

      body = %{
        "file_name" => file_name,
        "parent_type" => "explorer",
        "parent_node" => parent_node,
        "size" => file_size
      }

      case Api.post("/drive/v1/files/upload_all", Map.put(body, "file", file_data)) do
        {:ok, data} ->
          {:ok,
           %{
             file_token: Map.get(data, "file_token"),
             file_name: file_name,
             size: file_size
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  # Download file
  defp download_file(args) do
    file_token = Map.get(args, "file_token")

    if is_nil(file_token) do
      {:error, "file_token is required for download action"}
    else
      case Api.download_file("/drive/v1/files/#{file_token}/download") do
        {:ok, binary_data} ->
          {:ok,
           %{
             file_content_base64: Base.encode64(binary_data),
             size: byte_size(binary_data)
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  defp format_file_info(file) do
    %{
      token: Map.get(file, "token"),
      name: Map.get(file, "name"),
      type: Map.get(file, "type"),
      created_time: Map.get(file, "created_time"),
      modified_time: Map.get(file, "modified_time"),
      size: Map.get(file, "size"),
      parent_token: Map.get(file, "parent_token")
    }
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, value}]

  defp maybe_add_body(map, _key, nil), do: map
  defp maybe_add_body(map, key, value), do: Map.put(map, key, value)

  defp format_error(%{code: code, message: msg}), do: "Feishu API error #{code}: #{msg}"
  defp format_error(%{code: code}), do: "Feishu API error #{code}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Error: #{inspect(reason)}"
end
