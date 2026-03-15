defmodule Nex.Agent.Tool.FeishuDoc do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour
  alias Nex.Agent.Feishu.Api

  def name, do: "feishu_doc"
  def description, do: "Create, read, and update Feishu documents."
  def category, do: :base

  def definition do
    %{
      name: "feishu_doc",
      description: "飞书文档操作工具。支持创建、读取、更新飞书云文档。",
      parameters: %{
        type: "object",
        properties: %{
          "action" => %{type: "string", enum: ["create", "read", "update"]},
          "title" => %{type: "string"},
          "document_id" => %{type: "string"},
          "content" => %{type: "string"},
          "folder_token" => %{type: "string"},
          "update_mode" => %{type: "string", enum: ["append", "overwrite"]}
        },
        required: ["action"]
      }
    }
  end

  def execute(args, _ctx) do
    action = Map.get(args, "action")

    case action do
      "create" -> create_document(args)
      "read" -> read_document(args)
      "update" -> update_document(args)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  defp create_document(args) do
    title =
      Map.get(args, "title") ||
        Map.get(args, "content", "新文档")
        |> String.split("\n")
        |> List.first()
        |> String.slice(0, 100)

    folder_token = Map.get(args, "folder_token")
    content = Map.get(args, "content", "")

    body = %{"document" => %{"title" => title}}

    body =
      if folder_token && folder_token != "",
        do: put_in(body, ["document", "folder_token"], folder_token),
        else: body

    case Api.post("/docx/v1/documents", body) do
      {:ok, data} ->
        doc_id = extract_doc_id(data)

        if doc_id do
          result = %{
            document_id: doc_id,
            title: title,
            url: "https://feishu.cn/docx/#{doc_id}",
            message: "文档创建成功"
          }

          if content && content != "" do
            blocks = convert_to_paragraph_blocks(content)

            case Api.post("/docx/v1/documents/#{doc_id}/blocks", %{"children" => blocks}) do
              {:ok, _} ->
                Map.put(result, :content_written, true)

              {:error, write_reason} ->
                Map.put(result, :content_written, false)
                |> Map.put(:content_error, format_error(write_reason))
            end
          else
            result
          end
        else
          {:error, "无法从响应中提取document_id"}
        end

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp extract_doc_id(data) do
    cond do
      Map.has_key?(data, "document") ->
        doc = Map.get(data, "document")
        Map.get(doc, "document_id") || Map.get(doc, "token")

      Map.has_key?(data, "document_id") ->
        Map.get(data, "document_id")

      Map.has_key?(data, "token") ->
        Map.get(data, "token")

      true ->
        nil
    end
  end

  defp read_document(args) do
    doc_id = Map.get(args, "document_id")

    if is_nil(doc_id) or doc_id == "",
      do: {:error, "document_id is required"},
      else: do_read(doc_id)
  end

  defp do_read(doc_id) do
    # Get document metadata
    case Api.get("/docx/v1/documents/#{doc_id}") do
      {:ok, data} when is_map(data) ->
        doc = Map.get(data, "document") || %{}
        title = Map.get(doc, "title", "")

        # Get document blocks (content)
        case Api.get("/docx/v1/documents/#{doc_id}/blocks", params: [{"page_size", 100}]) do
          {:ok, blocks_data} ->
            items = get_in(blocks_data, ["data", "items"]) || []
            content = parse_blocks_to_text(items)

            {:ok,
             %{
               document_id: doc_id,
               title: title,
               content: content,
               url: "https://feishu.cn/docx/#{doc_id}",
               block_count: length(items)
             }}

          {:error, _reason} ->
            # Return document info even if blocks fetch fails
            {:ok,
             %{
               document_id: doc_id,
               title: title,
               content: "",
               url: "https://feishu.cn/docx/#{doc_id}",
               block_count: 0
             }}
        end

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp parse_blocks_to_text(blocks) when is_list(blocks) do
    blocks |> Enum.map_join("\n", &block_to_text/1)
  end

  defp parse_blocks_to_text(_), do: ""

  defp block_to_text(block) do
    block_type = Map.get(block, "block_type")

    case block_type do
      # Paragraph (2)
      "2" ->
        elements = Map.get(block, "paragraph", %{}) |> Map.get("elements", [])
        text = Enum.map_join(elements, "", &extract_text_from_element/1)
        text

      # Heading 1 (1)
      "1" ->
        elements = Map.get(block, "heading1", %{}) |> Map.get("elements", [])
        text = Enum.map_join(elements, "", &extract_text_from_element/1)
        "## " <> text

      # Heading 2 (3)
      "3" ->
        elements = Map.get(block, "heading2", %{}) |> Map.get("elements", [])
        text = Enum.map_join(elements, "", &extract_text_from_element/1)
        "### " <> text

      # Heading 3 (4)
      "4" ->
        elements = Map.get(block, "heading3", %{}) |> Map.get("elements", [])
        text = Enum.map_join(elements, "", &extract_text_from_element/1)
        "#### " <> text

      # Code (13)
      "13" ->
        language = Map.get(block, "code", %{}) |> Map.get("language", "")
        text = Map.get(block, "code", %{}) |> Map.get("content", "")
        "```#{language}\n#{text}\n```"

      # Quote (7)
      "7" ->
        elements = Map.get(block, "quote", %{}) |> Map.get("elements", [])
        text = Enum.map_join(elements, "", &extract_text_from_element/1)
        "> " <> text

      # Divider (18)
      "18" ->
        "---"

      # Table (19)
      "19" ->
        "【表格】"

      # Image (20)
      "20" ->
        "【图片】"

      # Unknown
      _ ->
        ""
    end
  end

  defp extract_text_from_element(element) do
    # Text run
    if Map.has_key?(element, "text_run") do
      Map.get(element, "text_run", %{}) |> Map.get("content", "")
      # Mention
    else
      if Map.has_key?(element, "mention") do
        Map.get(element, "mention", %{}) |> Map.get("name", "@mention")
        # Link
      else
        if Map.has_key?(element, "link") do
          Map.get(element, "link", %{}) |> Map.get("text", "")
        else
          ""
        end
      end
    end
  end

  defp update_document(args) do
    doc_id = Map.get(args, "document_id")
    content = Map.get(args, "content", "")
    update_mode = Map.get(args, "update_mode", "append")

    if is_nil(doc_id) or doc_id == "",
      do: {:error, "document_id is required"},
      else: do_update(doc_id, content, update_mode)
  end

  defp do_update(doc_id, content, update_mode) do
    case update_mode do
      "overwrite" -> overwrite_document(doc_id, content)
      _ -> append_to_document(doc_id, content)
    end
  end

  defp append_to_document(doc_id, content) do
    blocks = convert_to_paragraph_blocks(content)
    body = %{"children" => blocks}

    case Api.post("/docx/v1/documents/#{doc_id}/blocks", body) do
      {:ok, _data} ->
        {:ok, %{document_id: doc_id, message: "内容追加成功", content_length: String.length(content)}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp overwrite_document(doc_id, content) do
    case Api.get("/docx/v1/documents/#{doc_id}/blocks", params: [{"page_size", 100}]) do
      {:ok, blocks_data} ->
        items = get_in(blocks_data, ["data", "items"]) || []
        block_ids = Enum.map(items, &Map.get(&1, "block_id"))

        if block_ids == [] do
          insert_new_content(doc_id, content, "覆盖成功")
        else
          delete_results =
            Enum.reduce(block_ids, [], fn block_id, acc ->
              case Api.delete("/docx/v1/documents/#{doc_id}/blocks/#{block_id}") do
                {:ok, _} -> [block_id | acc]
                {:error, _} -> acc
              end
            end)

          deleted_count = length(delete_results)
          insert_new_content(doc_id, content, "覆盖成功（已删除#{deleted_count}个旧块）")
        end

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp insert_new_content(doc_id, content, success_msg) do
    blocks = convert_to_paragraph_blocks(content)
    body = %{"children" => blocks}

    case Api.post("/docx/v1/documents/#{doc_id}/blocks", body) do
      {:ok, _data} ->
        {:ok,
         %{document_id: doc_id, message: success_msg, content_length: String.length(content)}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp convert_to_paragraph_blocks(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(fn line ->
      %{
        "block_type" => "2",
        "paragraph" => %{"elements" => [%{"text_run" => %{"content" => line}}]}
      }
    end)
  end

  defp convert_to_paragraph_blocks(_), do: []

  defp format_error(%{code: c, message: m}), do: "Feishu API error #{c}: #{m}"
  defp format_error(%{code: c}), do: "Feishu API error #{c}"
  defp format_error(r) when is_binary(r), do: r
  defp format_error(r), do: "Error: #{inspect(r)}"
end
