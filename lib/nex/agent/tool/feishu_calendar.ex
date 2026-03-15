defmodule Nex.Agent.Tool.FeishuCalendar do
  @moduledoc """
  Feishu Calendar tool - Manage calendars and events.

  Based on OpenClaw's feishu_calendar_* tools.

  Actions: calendar_list, event_create, event_list, event_get, event_update, event_delete
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Feishu.Api

  def name, do: "feishu_calendar"
  def description, do: "Manage Feishu calendars and events."
  def category, do: :base

  def definition do
    %{
      name: "feishu_calendar",
      description: """
      飞书日历管理工具。

      ## Actions

      ### 日历
      - **calendar_list**: 列出日历
      - **calendar_create**: 创建日历
      - **calendar_get**: 获取日历详情

      ### 事件
      - **event_create**: 创建日程
      - **event_list**: 列出日程
      - **event_get**: 获取日程详情
      - **event_update**: 更新日程
      - **event_delete**: 删除日程
      - **event_attendee**: 管理参与人

      ## 时间格式

      - ISO 8601 格式，如：2024-01-01T09:00:00+08:00
      """,
      parameters: %{
        type: "object",
        properties: %{
          "action" => %{
            type: "string",
            enum: [
              "calendar_list",
              "calendar_create",
              "calendar_get",
              "event_create",
              "event_list",
              "event_get",
              "event_update",
              "event_delete"
            ],
            description: "操作类型"
          },
          "calendar_id" => %{
            type: "string",
            description: "日历ID（event操作时使用，默认primary）"
          },
          "event_id" => %{
            type: "string",
            description: "日程ID（event_get/update/delete时使用）"
          },
          "summary" => %{
            type: "string",
            description: "日程标题（event_create/update时使用）"
          },
          "description" => %{
            type: "string",
            description: "日程描述"
          },
          "start_time" => %{
            type: "string",
            description: "开始时间（ISO 8601格式）"
          },
          "end_time" => %{
            type: "string",
            description: "结束时间（ISO 8601格式）"
          },
          "attendees" => %{
            type: "array",
            description: "参与人ID列表",
            items: %{type: "string"}
          },
          "location" => %{
            type: "string",
            description: "地点"
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
      "calendar_list" -> list_calendars(args)
      "calendar_create" -> create_calendar(args)
      "calendar_get" -> get_calendar(args)
      "event_create" -> create_event(args)
      "event_list" -> list_events(args)
      "event_get" -> get_event(args)
      "event_update" -> update_event(args)
      "event_delete" -> delete_event(args)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # Calendar operations
  defp list_calendars(args) do
    page_size = Map.get(args, "page_size", 50)
    page_token = Map.get(args, "page_token")

    params = [{"page_size", page_size}] |> maybe_add_param("page_token", page_token)

    case Api.get("/calendar/v3/calendars", params: params) do
      {:ok, data} ->
        items = Map.get(data, "items", [])

        {:ok,
         %{
           calendars: Enum.map(items, &format_calendar/1),
           has_more: Map.get(data, "has_more", false),
           page_token: Map.get(data, "page_token")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp create_calendar(args) do
    name = Map.get(args, "name", "新日历")
    description = Map.get(args, "description", "")

    body = %{
      "calendar" => %{
        "summary" => name,
        "description" => description
      }
    }

    case Api.post("/calendar/v3/calendars", body) do
      {:ok, data} ->
        calendar = Map.get(data, "calendar", %{})

        {:ok,
         %{
           calendar_id: Map.get(calendar, "calendar_id"),
           summary: name
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp get_calendar(args) do
    calendar_id = Map.get(args, "calendar_id", "primary")
    do_get_calendar(calendar_id)
  end

  defp do_get_calendar(calendar_id) do
    case Api.get("/calendar/v3/calendars/#{calendar_id}") do
      {:ok, data} -> {:ok, %{calendar: Map.get(data, "calendar", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  # Event operations
  defp create_event(args) do
    calendar_id = Map.get(args, "calendar_id", "primary")
    summary = Map.get(args, "summary", "新日程")
    description = Map.get(args, "description", "")
    start_time = Map.get(args, "start_time")
    end_time = Map.get(args, "end_time")
    attendees = Map.get(args, "attendees", [])
    location = Map.get(args, "location", "")

    if is_nil(start_time) or is_nil(end_time) do
      {:error, "start_time and end_time are required"}
    else
      body = %{
        "event" => %{
          "summary" => summary,
          "description" => description,
          "start" => %{"time_zone" => "Asia/Shanghai", "timestamp" => to_timestamp(start_time)},
          "end" => %{"time_zone" => "Asia/Shanghai", "timestamp" => to_timestamp(end_time)},
          "location" => %{"name" => location},
          "attendees" => Enum.map(attendees, &%{"member_id" => %{"open_id" => &1}})
        }
      }

      case Api.post("/calendar/v3/calendars/#{calendar_id}/events", body) do
        {:ok, data} ->
          event = Map.get(data, "event", %{})

          {:ok,
           %{
             event_id: Map.get(event, "event_id"),
             summary: summary,
             html_link: Map.get(event, "html_link")
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  defp list_events(args) do
    calendar_id = Map.get(args, "calendar_id", "primary")
    page_size = Map.get(args, "page_size", 50)
    page_token = Map.get(args, "page_token")

    params = [{"page_size", page_size}] |> maybe_add_param("page_token", page_token)

    case Api.get("/calendar/v3/calendars/#{calendar_id}/events", params: params) do
      {:ok, data} ->
        items = Map.get(data, "items", [])

        {:ok,
         %{
           events: Enum.map(items, &format_event/1),
           has_more: Map.get(data, "has_more", false),
           page_token: Map.get(data, "page_token")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp get_event(args) do
    calendar_id = Map.get(args, "calendar_id", "primary")
    event_id = Map.get(args, "event_id")

    if is_nil(event_id),
      do: {:error, "event_id is required"},
      else: do_get_event(calendar_id, event_id)
  end

  defp do_get_event(calendar_id, event_id) do
    case Api.get("/calendar/v3/calendars/#{calendar_id}/events/#{event_id}") do
      {:ok, data} -> {:ok, %{event: Map.get(data, "event", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp update_event(args) do
    calendar_id = Map.get(args, "calendar_id", "primary")
    event_id = Map.get(args, "event_id")
    summary = Map.get(args, "summary")
    description = Map.get(args, "description")
    start_time = Map.get(args, "start_time")
    end_time = Map.get(args, "end_time")

    if is_nil(event_id),
      do: {:error, "event_id is required"},
      else: do_update_event(calendar_id, event_id, summary, description, start_time, end_time)
  end

  defp do_update_event(calendar_id, event_id, summary, description, start_time, end_time) do
    body =
      %{"event" => %{}}
      |> maybe_put("summary", summary)
      |> maybe_put("description", description)
      |> maybe_put_in(["start", "time_zone"], "Asia/Shanghai")
      |> maybe_put_in(["start", "timestamp"], to_timestamp(start_time))
      |> maybe_put_in(["end", "time_zone"], "Asia/Shanghai")
      |> maybe_put_in(["end", "timestamp"], to_timestamp(end_time))

    case Api.patch("/calendar/v3/calendars/#{calendar_id}/events/#{event_id}", body) do
      {:ok, data} -> {:ok, %{event: Map.get(data, "event", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp delete_event(args) do
    calendar_id = Map.get(args, "calendar_id", "primary")
    event_id = Map.get(args, "event_id")

    if is_nil(event_id),
      do: {:error, "event_id is required"},
      else: do_delete_event(calendar_id, event_id)
  end

  defp do_delete_event(calendar_id, event_id) do
    case Api.delete("/calendar/v3/calendars/#{calendar_id}/events/#{event_id}") do
      {:ok, _data} -> {:ok, %{success: true, event_id: event_id}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp format_calendar(cal) do
    %{
      calendar_id: Map.get(cal, "calendar_id"),
      summary: Map.get(cal, "summary"),
      description: Map.get(cal, "description"),
      role: Map.get(cal, "role")
    }
  end

  defp format_event(event) do
    start = Map.get(event, "start", %{})
    ending = Map.get(event, "end", %{})

    %{
      event_id: Map.get(event, "event_id"),
      summary: Map.get(event, "summary"),
      description: Map.get(event, "description"),
      start_time: Map.get(start, "timestamp"),
      end_time: Map.get(ending, "timestamp"),
      html_link: Map.get(event, "html_link")
    }
  end

  defp to_timestamp(iso_time) when is_binary(iso_time) do
    case DateTime.from_iso8601(iso_time) do
      {:ok, dt, _} -> DateTime.to_unix(dt) |> Integer.to_string()
      _ -> nil
    end
  end

  defp to_timestamp(_), do: nil

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, to_string(value)}]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_in(map, _path, nil), do: map
  defp maybe_put_in(map, [k], value), do: Map.put(map, k, value)

  defp maybe_put_in(map, [h | t], value),
    do: Map.put(map, h, maybe_put_in(Map.get(map, h, %{}), t, value))

  defp format_error(%{code: code, message: msg}), do: "Feishu API error #{code}: #{msg}"
  defp format_error(%{code: code}), do: "Feishu API error #{code}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Error: #{inspect(reason)}"
end
