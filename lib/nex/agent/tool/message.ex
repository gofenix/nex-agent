defmodule Nex.Agent.Tool.Message do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "message"
  def description, do: "Send a message to the user immediately."
  def category, do: :base

  def definition do
    %{
      name: "message",
      description:
        "Send a message to the user. Use this when you want to communicate something immediately. For Feishu, you can send structured native message types by providing msg_type plus content_json, upload and send a local PNG/JPEG via local_image_path, or provide both content and local_image_path to send a short text followed by the image.",
      parameters: %{
        type: "object",
        properties: %{
          content: %{type: "string", description: "The message content to send"},
          msg_type: %{
            type: "string",
            description:
              "Optional explicit message type for channels that support structured messages, such as Feishu. Feishu examples: text, post, interactive, image, file, audio, media, sticker, share_chat, share_user, system."
          },
          content_json: %{
            type: ["object", "string"],
            description:
              "Optional structured message payload. For Feishu this should be the raw content JSON object/string for the specified msg_type. Examples: image => {image_key}, file/audio/media/sticker => {file_key}, share_chat => {chat_id}, share_user => {user_id}, text => {text}, system => {type, params}."
          },
          local_image_path: %{
            type: "string",
            description:
              "Optional absolute or workspace-relative path to a local image file. For Feishu, the runtime uploads it and sends a native image message. If content or content_json is also present, Feishu sends that message first and then the image."
          },
          receive_id_type: %{
            type: "string",
            description:
              "Optional explicit recipient ID type for Feishu (open_id, chat_id, user_id, union_id, email)."
          },
          channel: %{
            type: "string",
            description:
              "Target channel (telegram, feishu, discord, http). Defaults to current channel."
          },
          chat_id: %{
            type: "string",
            description: "Target chat/user ID. Defaults to current chat."
          }
        },
        description: "Provide at least one of content, content_json, or local_image_path.",
        required: []
      }
    }
  end

  def execute(args, ctx) do
    require Logger
    Logger.info("Message Tool Execute - Args: #{inspect(args)}, Ctx: #{inspect(ctx)}")

    content = Map.get(args, "content")
    content_json = Map.get(args, "content_json")
    local_image_path = Map.get(args, "local_image_path")
    has_local_image = is_binary(local_image_path) and local_image_path != ""
    has_message_payload = present_message_payload?(content, content_json)

    if has_message_payload || has_local_image do
      publish_message(%{
        content: content,
        content_json: content_json,
        channel: Map.get(args, "channel") || Map.get(ctx, :channel, "telegram"),
        chat_id: Map.get(args, "chat_id") || Map.get(ctx, :chat_id, ""),
        msg_type: Map.get(args, "msg_type"),
        receive_id_type: Map.get(args, "receive_id_type"),
        local_image_path: local_image_path,
        has_local_image: has_local_image,
        has_message_payload: has_message_payload,
        ctx: ctx
      })
    else
      {:error, "content, content_json, or local_image_path is required"}
    end
  end

  defp publish_message(message) do
    require Logger
    topic = outbound_topic(message.channel)

    metadata =
      Map.get(message.ctx, :metadata, %{})
      |> Map.put("_from_tool", true)
      |> maybe_put("msg_type", message.msg_type)
      |> maybe_put("content_json", message.content_json)
      |> maybe_put("receive_id_type", message.receive_id_type)

    payload = %{chat_id: message.chat_id, content: message.content, metadata: metadata}
    Logger.info("Message Tool Publishing to #{topic}: #{inspect(payload)}")

    case message.channel do
      "feishu" -> publish_feishu(message, metadata, topic, payload)
      _ -> publish_non_feishu(message, topic, payload)
    end
  end

  defp outbound_topic("telegram"), do: :telegram_outbound
  defp outbound_topic("feishu"), do: :feishu_outbound
  defp outbound_topic("discord"), do: :discord_outbound
  defp outbound_topic("http"), do: :http_outbound
  defp outbound_topic(_channel), do: :outbound

  defp publish_feishu(message, metadata, topic, payload) do
    cond do
      message.has_local_image and message.has_message_payload ->
        deliver_feishu_text_and_image(message, metadata)

      message.has_local_image ->
        deliver_feishu_image(message, metadata)

      Process.whereis(Nex.Agent.Channel.Feishu) ->
        deliver_feishu_text(message, metadata)

      true ->
        Nex.Agent.Bus.publish(topic, payload)
        sent_result(message)
    end
  end

  defp deliver_feishu_text_and_image(message, metadata) do
    if Process.whereis(Nex.Agent.Channel.Feishu) do
      with :ok <-
             Nex.Agent.Channel.Feishu.deliver_message(
               message.chat_id,
               message.content,
               feishu_companion_metadata(metadata)
             ),
           :ok <-
             Nex.Agent.Channel.Feishu.deliver_local_image(
               message.chat_id,
               message.local_image_path,
               metadata
             ) do
        {:ok,
         %{
           sent: true,
           channel: message.channel,
           chat_id: message.chat_id,
           delivered: ["message", "image"]
         }}
      else
        {:error, reason} ->
          {:error, "Feishu text+image send failed: #{inspect(reason)}"}
      end
    else
      {:error, "Feishu text+image send requires the Feishu channel process to be running"}
    end
  end

  defp deliver_feishu_image(message, metadata) do
    if Process.whereis(Nex.Agent.Channel.Feishu) do
      case Nex.Agent.Channel.Feishu.deliver_local_image(
             message.chat_id,
             message.local_image_path,
             metadata
           ) do
        :ok ->
          sent_result(message)

        {:error, reason} ->
          {:error, "Feishu image send failed: #{inspect(reason)}"}
      end
    else
      {:error, "Feishu image send requires the Feishu channel process to be running"}
    end
  end

  defp deliver_feishu_text(message, metadata) do
    case Nex.Agent.Channel.Feishu.deliver_message(message.chat_id, message.content, metadata) do
      :ok ->
        sent_result(message)

      {:error, reason} ->
        {:error, "Feishu send failed: #{inspect(reason)}"}
    end
  end

  defp publish_non_feishu(message, topic, payload) do
    if message.has_local_image do
      {:error, "local_image_path is currently only supported for Feishu"}
    else
      Nex.Agent.Bus.publish(topic, payload)
      sent_result(message)
    end
  end

  defp sent_result(message) do
    {:ok, %{sent: true, channel: message.channel, chat_id: message.chat_id}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present_message_payload?(content, content_json) do
    (is_binary(content) and String.trim(content) != "") or not is_nil(content_json)
  end

  defp feishu_companion_metadata(metadata) do
    metadata
  end
end
