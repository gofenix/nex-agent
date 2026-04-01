defmodule Nex.Agent.MessageToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Bus
  alias Nex.Agent.Channel.Feishu
  alias Nex.Agent.Config
  alias Nex.Agent.Tool.Message

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    Bus.subscribe(:feishu_outbound)

    on_exit(fn ->
      Bus.unsubscribe(:feishu_outbound)
    end)

    :ok
  end

  test "message tool preserves legacy behavior with plain content" do
    assert {:ok, %{sent: true, channel: "feishu", chat_id: "ou_123"}} =
             Message.execute(
               %{"content" => "hello", "channel" => "feishu", "chat_id" => "ou_123"},
               %{}
             )

    assert_receive {:bus_message, :feishu_outbound, payload}
    assert payload.content == "hello"
    assert payload.metadata["_from_tool"] == true
    refute Map.has_key?(payload.metadata, "msg_type")
  end

  test "message tool forwards explicit feishu structured message metadata" do
    assert {:ok, %{sent: true, channel: "feishu", chat_id: "oc_123"}} =
             Message.execute(
               %{
                 "channel" => "feishu",
                 "chat_id" => "oc_123",
                 "msg_type" => "image",
                 "content_json" => %{"image_key" => "img_123"},
                 "receive_id_type" => "chat_id"
               },
               %{}
             )

    assert_receive {:bus_message, :feishu_outbound, payload}
    assert payload.content == nil
    assert payload.metadata["msg_type"] == "image"
    assert payload.metadata["content_json"] == %{"image_key" => "img_123"}
    assert payload.metadata["receive_id_type"] == "chat_id"
  end

  test "message tool uses synchronous Feishu delivery when default channel process is running" do
    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_sync"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_post_multipart_fun = fn url, body, headers ->
      send(parent, {:http_post_multipart, url, body, headers})

      if String.contains?(url, "/im/v1/images") do
        {:ok, %{"code" => 0, "data" => %{"image_key" => "img_sync"}}}
      else
        {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    config = %Config{Config.default() | feishu: %{"enabled" => false}}

    pid =
      start_supervised!(
        {Feishu,
         name: Feishu,
         config: config,
         http_post_fun: http_post_fun,
         http_post_multipart_fun: http_post_multipart_fun,
         http_get_fun: fn _url, _headers -> {:error, :unexpected} end}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    assert {:ok, %{sent: true, channel: "feishu", chat_id: "ou_sync"}} =
             Message.execute(
               %{"content" => "sync hello", "channel" => "feishu", "chat_id" => "ou_sync"},
               %{}
             )

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["receive_id"] == "ou_sync"
  end

  test "message tool uploads local image path for Feishu" do
    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_img"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_post_multipart_fun = fn url, body, headers ->
      send(parent, {:http_post_multipart, url, body, headers})

      if String.contains?(url, "/im/v1/images") do
        {:ok, %{"code" => 0, "data" => %{"image_key" => "img_sync"}}}
      else
        {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    config = %Config{Config.default() | feishu: %{"enabled" => false}}

    pid =
      start_supervised!(
        {Feishu,
         name: Feishu,
         config: config,
         http_post_fun: http_post_fun,
         http_post_multipart_fun: http_post_multipart_fun,
         http_get_fun: fn _url, _headers -> {:error, :unexpected} end}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    path =
      Path.join(System.tmp_dir!(), "message_tool_image_#{System.unique_integer([:positive])}.png")

    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{sent: true, channel: "feishu", chat_id: "ou_sync_img"}} =
             Message.execute(
               %{
                 "channel" => "feishu",
                 "chat_id" => "ou_sync_img",
                 "local_image_path" => path
               },
               %{}
             )

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post_multipart, upload_url, multipart_body, _headers2}
    assert upload_url =~ "/im/v1/images"
    assert Keyword.get(multipart_body, :image_type) == "message"

    assert_receive {:http_post, url2, body2, _headers3}
    assert url2 =~ "/im/v1/messages"
    assert body2["receive_id"] == "ou_sync_img"
    assert body2["msg_type"] == "image"
    assert Jason.decode!(body2["content"]) == %{"image_key" => "img_sync"}
  end

  test "message tool sends native text before local image for Feishu companion sends" do
    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_combo"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_post_multipart_fun = fn url, body, headers ->
      send(parent, {:http_post_multipart, url, body, headers})

      if String.contains?(url, "/im/v1/images") do
        {:ok, %{"code" => 0, "data" => %{"image_key" => "img_combo"}}}
      else
        {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    config = %Config{Config.default() | feishu: %{"enabled" => false}}

    pid =
      start_supervised!(
        {Feishu,
         name: Feishu,
         config: config,
         http_post_fun: http_post_fun,
         http_post_multipart_fun: http_post_multipart_fun,
         http_get_fun: fn _url, _headers -> {:error, :unexpected} end}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    path =
      Path.join(System.tmp_dir!(), "message_tool_combo_#{System.unique_integer([:positive])}.png")

    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    on_exit(fn -> File.rm(path) end)

    assert {:ok,
            %{sent: true, channel: "feishu", chat_id: "ou_combo", delivered: ["message", "image"]}} =
             Message.execute(
               %{
                 "channel" => "feishu",
                 "chat_id" => "ou_combo",
                 "content" => "海报已生成，见下图。",
                 "local_image_path" => path
               },
               %{}
             )

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["receive_id"] == "ou_combo"
    assert body2["msg_type"] == "text"
    assert Jason.decode!(body2["content"]) == %{"text" => "海报已生成，见下图。"}

    assert_receive {:http_post_multipart, upload_url, multipart_body, _headers3}
    assert upload_url =~ "/im/v1/images"
    assert Keyword.get(multipart_body, :image_type) == "message"

    assert_receive {:http_post, url3, body3, _headers4}
    assert url3 =~ "/im/v1/messages"
    assert body3["receive_id"] == "ou_combo"
    assert body3["msg_type"] == "image"
    assert Jason.decode!(body3["content"]) == %{"image_key" => "img_combo"}
  end
end
