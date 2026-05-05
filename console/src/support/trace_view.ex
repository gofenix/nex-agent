defmodule NexAgentConsole.Support.TraceView do
  @moduledoc false

  @spec format_timestamp(term()) :: String.t()
  def format_timestamp(nil), do: "unknown"
  def format_timestamp(""), do: "unknown"

  def format_timestamp(%DateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")

  def format_timestamp(%NaiveDateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")

  def format_timestamp(value) when is_integer(value) do
    value
    |> DateTime.from_unix!()
    |> format_timestamp()
  rescue
    _ -> "unknown"
  end

  def format_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        format_timestamp(datetime)

      _ ->
        value
        |> String.replace("T", " ")
        |> String.replace("Z", "")
        |> String.slice(0, 19)
    end
  end

  def format_timestamp(_), do: "unknown"

  @spec status_class(term()) :: String.t()
  def status_class(status) when status in ["completed", "ok", :completed, :ok],
    do: "status-dot--completed"

  def status_class(status) when status in ["failed", "error", :failed, :error],
    do: "status-dot--failed"

  def status_class(_), do: "status-dot--running"

  @spec status_label(term()) :: String.t()
  def status_label(nil), do: "running"
  def status_label(status) when is_atom(status), do: Atom.to_string(status)
  def status_label(status), do: to_string(status)

  @spec event_class(map()) :: String.t()
  def event_class(%{"type" => type}) when type in ["llm_request", "llm_response"],
    do: "event--llm"

  def event_class(%{"type" => "tool_result"}), do: "event--tool"
  def event_class(%{"status" => status}) when status in ["failed", "error"], do: "event--failed"
  def event_class(_), do: ""

  @spec event_title(map()) :: String.t()
  def event_title(%{"type" => "request_started"}), do: "request_started"
  def event_title(%{"type" => "request_completed"}), do: "request_completed"

  def event_title(%{"type" => "llm_request"} = event),
    do: "llm_request · round #{event["iteration"] || "?"}"

  def event_title(%{"type" => "llm_response"} = event),
    do: "llm_response · round #{event["iteration"] || "?"}"

  def event_title(%{"type" => "tool_result"} = event),
    do: "tool_result · #{event["tool"] || "unknown"}"

  def event_title(%{"type" => type}) when is_binary(type), do: type
  def event_title(_), do: "event"

  @spec event_summary(map()) :: String.t()
  def event_summary(%{"type" => "request_started"} = event) do
    prompt = event |> Map.get("prompt") |> preview(220)
    channel = event["channel"] || "unknown channel"
    chat_id = event["chat_id"] || "unknown chat"
    Enum.join([channel, chat_id, prompt], " · ")
  end

  def event_summary(%{"type" => "llm_request"} = event) do
    messages = event["messages"] || []
    tools = event["tools"] || []
    "#{length(messages)} messages · #{length(tools)} available tools"
  end

  def event_summary(%{"type" => "llm_response"} = event) do
    tool_calls = event_tool_calls(event)
    content = preview(event["content"], 240)

    cond do
      tool_calls != [] -> "#{length(tool_calls)} tool calls"
      content != "" -> content
      true -> "No assistant text content"
    end
  end

  def event_summary(%{"type" => "tool_result"} = event), do: preview(event["content"], 240)

  def event_summary(%{"type" => "request_completed"} = event) do
    [event["status"] || "completed", preview(event["result"], 220)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def event_summary(event), do: preview(event, 240)

  @spec event_messages(map()) :: list()
  def event_messages(%{"type" => "llm_request", "messages" => messages}) when is_list(messages),
    do: messages

  def event_messages(_), do: []

  @spec event_tools(map()) :: list()
  def event_tools(%{"type" => "llm_request", "tools" => tools}) when is_list(tools), do: tools
  def event_tools(_), do: []

  @spec event_tool_calls(map()) :: list()
  def event_tool_calls(%{"type" => "llm_response", "tool_calls" => tool_calls})
      when is_list(tool_calls),
      do: tool_calls

  def event_tool_calls(%{"type" => "llm_response", "content" => content}) when is_list(content) do
    Enum.filter(content, fn item ->
      value(item, :type) == "tool_use" or value(item, :name) != nil or
        value(item, :function) != nil
    end)
  end

  def event_tool_calls(_), do: []

  @spec message_role(term()) :: String.t()
  def message_role(message), do: message |> value(:role) |> text_or("unknown")

  @spec message_preview(term()) :: String.t()
  def message_preview(message) do
    case value(message, :content) do
      content when is_binary(content) ->
        preview(content, 260)

      content when is_list(content) ->
        content
        |> Enum.map(&content_part_preview/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" · ")
        |> preview(260)

      content ->
        preview(content, 260)
    end
  end

  @spec tool_name(term()) :: String.t()
  def tool_name(tool), do: tool |> value(:name) |> text_or("unknown_tool")

  @spec tool_description(term()) :: String.t()
  def tool_description(tool), do: tool |> value(:description) |> preview(260)

  @spec tool_parameters(term()) :: term()
  def tool_parameters(tool), do: value(tool, :input_schema) || value(tool, :parameters) || %{}

  @spec tool_call_name(term()) :: String.t()
  def tool_call_name(tool_call) do
    function = value(tool_call, :function) || %{}

    text_or(value(tool_call, :name) || value(function, :name), "unknown_tool")
  end

  @spec tool_call_id(term()) :: String.t()
  def tool_call_id(tool_call), do: tool_call |> value(:id) |> text_or("")

  @spec tool_call_arguments(term()) :: term()
  def tool_call_arguments(tool_call) do
    function = value(tool_call, :function) || %{}

    arguments =
      [
        value(tool_call, :input),
        value(tool_call, :arguments),
        value(function, :arguments)
      ]
      |> Enum.find(&(!is_nil(&1)))
      |> decode_json_string()

    arguments || %{}
  end

  @spec json_dump(term()) :: String.t()
  def json_dump(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(value, pretty: true, printable_limit: 100_000, limit: :infinity)
    end
  end

  @spec preview(term(), pos_integer()) :: String.t()
  def preview(nil, _max), do: ""

  def preview(value, max) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max)
  end

  def preview(value, max) do
    value
    |> inspect(pretty: false, printable_limit: max, limit: 20)
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, max)
  end

  defp content_part_preview(part) do
    case value(part, :type) do
      "text" -> part |> value(:text) |> preview(180)
      "tool_use" -> "tool_use: #{tool_call_name(part)}"
      _ -> preview(part, 180)
    end
  end

  defp text_or(nil, fallback), do: fallback
  defp text_or("", fallback), do: fallback
  defp text_or(value, _fallback) when is_binary(value), do: value
  defp text_or(value, _fallback), do: to_string(value)

  defp decode_json_string(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end

  defp decode_json_string(value), do: value

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_, _), do: nil
end
