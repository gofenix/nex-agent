defmodule Nex.Agent.Tool.FeishuBitable do
  @moduledoc """
  Feishu Bitable tool - Manage multi-dimensional tables (Bitable).

  Based on OpenClaw's feishu_bitable_* tools.

  Actions: app_create, app_list, app_get, table_create, table_list, record_create, record_list, record_update, record_delete
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Feishu.Api

  def name, do: "feishu_bitable"
  def description, do: "Manage Feishu Bitable (multi-dimensional tables)."
  def category, do: :base

  def definition do
    %{
      name: "feishu_bitable",
      description: """
      飞书多维表格（Bitable）管理工具。

      ## Actions

      ### 应用级别
      - **app_create**: 创建多维表格应用
      - **app_list**: 列出多维表格应用
      - **app_get**: 获取应用详情

      ### 数据表级别
      - **table_create**: 创建数据表
      - **table_list**: 列出数据表
      - **table_get**: 获取数据表详情

      ### 记录级别
      - **record_create**: 创建记录
      - **record_list**: 列出记录
      - **record_update**: 更新记录
      - **record_delete**: 删除记录
      """,
      parameters: %{
        type: "object",
        properties: %{
          "action" => %{
            type: "string",
            enum: [
              "app_create",
              "app_list",
              "app_get",
              "table_create",
              "table_list",
              "table_get",
              "record_create",
              "record_list",
              "record_update",
              "record_delete"
            ],
            description: "操作类型"
          },
          "app_token" => %{
            type: "string",
            description: "多维表格应用token（app/table/record操作时使用）"
          },
          "table_id" => %{
            type: "string",
            description: "数据表ID（table/record操作时使用）"
          },
          "name" => %{
            type: "string",
            description: "名称（app_create/table_create时使用）"
          },
          "folder_token" => %{
            type: "string",
            description: "父文件夹token（app_create时使用）"
          },
          "fields" => %{
            type: "array",
            description: "字段定义数组（table_create时使用）",
            items: %{
              type: "object",
              properties: %{
                "field_name" => %{type: "string"},
                "field_type" => %{
                  type: "string",
                  enum: [
                    "Text",
                    "Number",
                    "SingleSelect",
                    "MultiSelect",
                    "Date",
                    "User",
                    "File",
                    "Url",
                    "Checkbox",
                    "Currency",
                    "Progress",
                    "Rating"
                  ]
                }
              }
            }
          },
          "records" => %{
            type: "array",
            description: "记录数组（record_create/list时使用）",
            items: %{type: "object"}
          },
          "record_id" => %{
            type: "string",
            description: "记录ID（record_update/delete时使用）"
          },
          "page_size" => %{
            type: "integer",
            description: "分页大小（list时使用，默认50，最大200）"
          },
          "page_token" => %{
            type: "string",
            description: "分页标记（list时使用）"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(args, _ctx) do
    action = Map.get(args, "action")

    case action do
      "app_create" -> create_app(args)
      "app_list" -> list_apps(args)
      "app_get" -> get_app(args)
      "table_create" -> create_table(args)
      "table_list" -> list_tables(args)
      "table_get" -> get_table(args)
      "record_create" -> create_record(args)
      "record_list" -> list_records(args)
      "record_update" -> update_record(args)
      "record_delete" -> delete_record(args)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # App operations
  defp create_app(args) do
    name = Map.get(args, "name", "新多维表格")
    folder_token = Map.get(args, "folder_token")

    body =
      %{"name" => name}
      |> maybe_add("folder_token", folder_token)

    case Api.post("/bitable/v1/apps", body) do
      {:ok, data} ->
        app = Map.get(data, "app", %{})

        {:ok,
         %{
           app_token: Map.get(app, "app_token"),
           name: name,
           url: "https://feishu.cn/base/#{Map.get(app, "app_token")}"
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp list_apps(args) do
    folder_token = Map.get(args, "folder_token", "")
    page_size = Map.get(args, "page_size", 50)
    page_token = Map.get(args, "page_token")

    params =
      [{"folder_token", folder_token}, {"page_size", page_size}]
      |> maybe_add_param("page_token", page_token)

    case Api.get("/drive/v1/files", params: params) do
      {:ok, data} ->
        files =
          Map.get(data, "files", []) |> Enum.filter(fn f -> Map.get(f, "type") == "bitable" end)

        {:ok,
         %{apps: Enum.map(files, &%{app_token: Map.get(&1, "token"), name: Map.get(&1, "name")})}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp get_app(args) do
    app_token = Map.get(args, "app_token")
    if is_nil(app_token), do: {:error, "app_token is required"}, else: do_get_app(app_token)
  end

  defp do_get_app(app_token) do
    case Api.get("/bitable/v1/apps/#{app_token}") do
      {:ok, data} -> {:ok, %{app: Map.get(data, "app", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  # Table operations
  defp create_table(args) do
    app_token = Map.get(args, "app_token")
    name = Map.get(args, "name", "新数据表")
    fields = Map.get(args, "fields", [])

    if is_nil(app_token),
      do: {:error, "app_token is required"},
      else: do_create_table(app_token, name, fields)
  end

  defp do_create_table(app_token, name, fields) do
    body = %{"table" => %{"name" => name, "fields" => fields}}

    case Api.post("/bitable/v1/apps/#{app_token}/tables", body) do
      {:ok, data} ->
        table = Map.get(data, "table", %{})
        {:ok, %{table_id: Map.get(table, "table_id"), name: name}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp list_tables(args) do
    app_token = Map.get(args, "app_token")
    if is_nil(app_token), do: {:error, "app_token is required"}, else: do_list_tables(app_token)
  end

  defp do_list_tables(app_token) do
    case Api.get("/bitable/v1/apps/#{app_token}/tables") do
      {:ok, data} -> {:ok, %{tables: Map.get(data, "items", [])}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp get_table(args) do
    app_token = Map.get(args, "app_token")
    table_id = Map.get(args, "table_id")

    if is_nil(app_token) or is_nil(table_id),
      do: {:error, "app_token and table_id are required"},
      else: do_get_table(app_token, table_id)
  end

  defp do_get_table(app_token, table_id) do
    case Api.get("/bitable/v1/apps/#{app_token}/tables/#{table_id}") do
      {:ok, data} -> {:ok, %{table: Map.get(data, "table", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  # Record operations
  defp create_record(args) do
    app_token = Map.get(args, "app_token")
    table_id = Map.get(args, "table_id")
    records = Map.get(args, "records", [])

    if is_nil(app_token) or is_nil(table_id),
      do: {:error, "app_token and table_id are required"},
      else: do_create_record(app_token, table_id, records)
  end

  defp do_create_record(app_token, table_id, records) do
    body = %{"records" => records}

    case Api.post("/bitable/v1/apps/#{app_token}/tables/#{table_id}/records", body) do
      {:ok, data} -> {:ok, %{records: Map.get(data, "data", %{}) |> Map.get("records", [])}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp list_records(args) do
    app_token = Map.get(args, "app_token")
    table_id = Map.get(args, "table_id")
    page_size = Map.get(args, "page_size", 50)
    page_token = Map.get(args, "page_token")

    if is_nil(app_token) or is_nil(table_id),
      do: {:error, "app_token and table_id are required"},
      else: do_list_records(app_token, table_id, page_size, page_token)
  end

  defp do_list_records(app_token, table_id, page_size, page_token) do
    params = [{"page_size", page_size}] |> maybe_add_param("page_token", page_token)

    case Api.get("/bitable/v1/apps/#{app_token}/tables/#{table_id}/records", params: params) do
      {:ok, data} ->
        records = Map.get(data, "items", [])

        {:ok,
         %{
           records: records,
           has_more: Map.get(data, "has_more", false),
           page_token: Map.get(data, "page_token")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp update_record(args) do
    app_token = Map.get(args, "app_token")
    table_id = Map.get(args, "table_id")
    record_id = Map.get(args, "record_id")
    records = Map.get(args, "records", [])

    if is_nil(app_token) or is_nil(table_id) or is_nil(record_id),
      do: {:error, "app_token, table_id, and record_id are required"},
      else: do_update_record(app_token, table_id, record_id, records)
  end

  defp do_update_record(app_token, table_id, record_id, records) do
    body = %{"records" => records}

    case Api.put("/bitable/v1/apps/#{app_token}/tables/#{table_id}/records", body) do
      {:ok, data} -> {:ok, %{success: true, data: Map.get(data, "data", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp delete_record(args) do
    app_token = Map.get(args, "app_token")
    table_id = Map.get(args, "table_id")
    record_id = Map.get(args, "record_id")

    if is_nil(app_token) or is_nil(table_id) or is_nil(record_id),
      do: {:error, "app_token, table_id, and record_id are required"},
      else: do_delete_record(app_token, table_id, record_id)
  end

  defp do_delete_record(app_token, table_id, record_id) do
    case Api.delete("/bitable/v1/apps/#{app_token}/tables/#{table_id}/records/#{record_id}") do
      {:ok, _data} -> {:ok, %{success: true, record_id: record_id}}
      {:error, reason} -> {:error, format_error(reason)}
    end
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
