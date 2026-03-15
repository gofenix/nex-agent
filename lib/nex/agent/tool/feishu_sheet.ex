defmodule Nex.Agent.Tool.FeishuSheet do
  @moduledoc """
  Feishu Sheet tool - Manage spreadsheets.

  Based on OpenClaw's feishu_sheet tool.

  Actions: info, read, write, append, create
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Feishu.Api

  def name, do: "feishu_sheet"
  def description, do: "Manage Feishu spreadsheets."
  def category, do: :base

  def definition do
    %{
      name: "feishu_sheet",
      description: """
      飞书电子表格工具。

      ## Actions

      - **info**: 获取表格信息和工作表列表
      - **read**: 读取工作表数据
      - **write**: 写入数据到指定范围
      - **append**: 追加数据到工作表末尾
      - **create**: 创建新的电子表格
      - **export**: 导出为Excel文件

      ## 注意事项

      - spreadsheet_token 可以从 URL 获取：https://feishu.cn/sheets/TOKEN
      - range 格式：Sheet1!A1:C10 或 A1:C10
      """,
      parameters: %{
        type: "object",
        properties: %{
          "action" => %{
            type: "string",
            enum: ["info", "read", "write", "append", "create", "export"],
            description: "操作类型"
          },
          "spreadsheet_token" => %{
            type: "string",
            description: "表格token（info/read/write/append/export时必填）"
          },
          "sheet_id" => %{
            type: "string",
            description: "工作表ID（read/write/append时使用）"
          },
          "range" => %{
            type: "string",
            description: "数据范围，如 A1:C10（read/write时使用）"
          },
          "values" => %{
            type: "array",
            description: "数据数组，二维数组，每行是一个数组（write/append时使用）",
            items: %{
              type: "array",
              items: %{type: ["string", "number", "boolean"]}
            }
          },
          "title" => %{
            type: "string",
            description: "表格标题（create时使用）"
          },
          "folder_token" => %{
            type: "string",
            description: "父文件夹token（create时使用，可选）"
          },
          "user_id_type" => %{
            type: "string",
            enum: ["open_id", "union_id", "user_id"],
            description: "用户ID类型（默认open_id）"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(args, _ctx) do
    action = Map.get(args, "action")

    case action do
      "info" -> get_info(args)
      "read" -> read_data(args)
      "write" -> write_data(args)
      "append" -> append_data(args)
      "create" -> create_spreadsheet(args)
      "export" -> export_spreadsheet(args)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # Get spreadsheet info
  defp get_info(args) do
    token = Map.get(args, "spreadsheet_token")

    if is_nil(token) or token == "" do
      {:error, "spreadsheet_token is required for info action"}
    else
      case Api.get("/sheets/v3/spreadsheets/#{token}") do
        {:ok, data} ->
          spreadsheet = Map.get(data, "spreadsheet", %{})
          sheets = Map.get(data, "sheets", [])

          {:ok,
           %{
             spreadsheet_token: token,
             title: Map.get(spreadsheet, "title"),
             owner_id: Map.get(spreadsheet, "owner_id"),
             sheets: Enum.map(sheets, &format_sheet_info/1)
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  # Read data from sheet
  defp read_data(args) do
    token = Map.get(args, "spreadsheet_token")
    sheet_id = Map.get(args, "sheet_id")
    range = Map.get(args, "range")

    if is_nil(token) or token == "" do
      {:error, "spreadsheet_token is required for read action"}
    else
      path = "/sheets/v2/spreadsheets/#{token}/values/#{range || "A1:Z1000"}"
      path = if sheet_id, do: "#{path}?sheetId=#{sheet_id}", else: path

      case Api.get(path) do
        {:ok, data} ->
          {:ok,
           %{
             values: Map.get(data, "valueRange", %{}) |> Map.get("values", [])
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  # Write data to sheet
  defp write_data(args) do
    token = Map.get(args, "spreadsheet_token")
    range = Map.get(args, "range", "A1")
    values = Map.get(args, "values", [])

    if is_nil(token) or token == "" do
      {:error, "spreadsheet_token is required for write action"}
    else
      body = %{
        "valueRange" => %{
          "range" => range,
          "values" => values
        }
      }

      case Api.put("/sheets/v2/spreadsheets/#{token}/values", body) do
        {:ok, _data} ->
          {:ok,
           %{
             success: true,
             range: range,
             rows_written: length(values)
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  # Append data to sheet
  defp append_data(args) do
    token = Map.get(args, "spreadsheet_token")
    values = Map.get(args, "values", [])

    if is_nil(token) or token == "" do
      {:error, "spreadsheet_token is required for append action"}
    else
      body = %{
        "valueRange" => %{
          "values" => values
        }
      }

      case Api.post("/sheets/v2/spreadsheets/#{token}/values_append", body) do
        {:ok, data} ->
          {:ok,
           %{
             success: true,
             updated_range: Map.get(data, "updatedRange"),
             rows_appended: Map.get(data, "updatedRows")
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  # Create new spreadsheet
  defp create_spreadsheet(args) do
    title = Map.get(args, "title", "新表格")
    folder_token = Map.get(args, "folder_token")

    body =
      %{"spreadsheet" => %{"title" => title}}
      |> maybe_add_body("folder_token", folder_token)

    case Api.post("/sheets/v3/spreadsheets", body) do
      {:ok, data} ->
        spreadsheet = Map.get(data, "spreadsheet", %{})

        {:ok,
         %{
           spreadsheet_token: Map.get(spreadsheet, "spreadsheet_token"),
           title: title,
           url: "https://feishu.cn/sheets/#{Map.get(spreadsheet, "spreadsheet_token")}"
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  # Export spreadsheet
  defp export_spreadsheet(args) do
    token = Map.get(args, "spreadsheet_token")
    sheet_id = Map.get(args, "sheet_id")

    if is_nil(token) or token == "" do
      {:error, "spreadsheet_token is required for export action"}
    else
      path = "/sheets/v2/spreadsheets/#{token}/export"
      params = if sheet_id, do: [{"sheetId", sheet_id}], else: []

      case Api.download_file(path, params: params) do
        {:ok, binary_data} ->
          {:ok,
           %{
             file_content_base64: Base.encode64(binary_data),
             size: byte_size(binary_data),
             format: "xlsx"
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  defp format_sheet_info(sheet) do
    %{
      sheet_id: Map.get(sheet, "sheet_id"),
      title: Map.get(sheet, "title"),
      index: Map.get(sheet, "index"),
      row_count: Map.get(sheet, "row_count"),
      column_count: Map.get(sheet, "column_count")
    }
  end

  defp maybe_add_body(map, _key, nil), do: map
  defp maybe_add_body(map, key, value), do: Map.put(map, key, value)

  defp format_error(%{code: code, message: msg}), do: "Feishu API error #{code}: #{msg}"
  defp format_error(%{code: code}), do: "Feishu API error #{code}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Error: #{inspect(reason)}"
end
