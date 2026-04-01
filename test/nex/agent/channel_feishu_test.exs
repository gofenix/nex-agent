defmodule Nex.Agent.Channel.FeishuTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.Feishu

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_123"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_get_fun = fn url, headers ->
      send(parent, {:http_get, url, headers})

      if String.contains?(url, "/im/v1/messages/") and String.contains?(url, "/resources/") do
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "image/png"}],
           body: <<137, 80, 78, 71, 13, 10, 26, 10>>
         }}
      else
        {:error, :unexpected}
      end
    end

    http_post_multipart_fun = fn url, body, headers ->
      send(parent, {:http_post_multipart, url, body, headers})

      if String.contains?(url, "/im/v1/images") do
        {:ok, %{"code" => 0, "data" => %{"image_key" => "img_uploaded"}}}
      else
        {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    config = %Config{Config.default() | feishu: %{"enabled" => false}}
    name = String.to_atom("feishu_test_#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {Feishu,
         name: name,
         config: config,
         http_post_fun: http_post_fun,
         http_post_multipart_fun: http_post_multipart_fun,
         http_get_fun: http_get_fun}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    Bus.subscribe(:inbound)

    on_exit(fn ->
      Bus.unsubscribe(:inbound)
    end)

    {:ok, pid: pid}
  end

  test "legacy outbound still defaults to interactive card", %{pid: _pid} do
    Bus.publish_sync(:feishu_outbound, %{
      chat_id: "ou_123",
      content: "hello world",
      metadata: %{}
    })

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["msg_type"] == "interactive"
    assert body2["receive_id"] == "ou_123"
    assert is_binary(body2["content"])
  end

  test "explicit image msg_type sends raw feishu payload", %{pid: _pid} do
    Bus.publish_sync(:feishu_outbound, %{
      chat_id: "oc_chat_123",
      content: nil,
      metadata: %{
        "msg_type" => "image",
        "content_json" => %{"image_key" => "img_123"},
        "receive_id_type" => "chat_id"
      }
    })

    assert_receive {:http_post, _, _, _}
    assert_receive {:http_post, url, body, _headers}

    assert url =~ "receive_id_type=chat_id"
    assert body["msg_type"] == "image"
    assert Jason.decode!(body["content"]) == %{"image_key" => "img_123"}
  end

  test "synchronous send_message call confirms Feishu delivery", %{pid: pid} do
    assert :ok = GenServer.call(pid, {:send_message, "ou_123", "hello sync", %{}})

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["receive_id"] == "ou_123"
    assert body2["msg_type"] == "interactive"
    assert is_binary(body2["content"])
  end

  test "synchronous local image send uploads and delivers native image message", %{pid: pid} do
    path =
      Path.join(System.tmp_dir!(), "feishu_test_image_#{System.unique_integer([:positive])}.png")

    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    on_exit(fn -> File.rm(path) end)

    assert :ok = GenServer.call(pid, {:send_local_image, "ou_123", path, %{}})

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post_multipart, upload_url, multipart_body, upload_headers}
    assert upload_url =~ "/im/v1/images"

    assert Enum.any?(upload_headers, fn {key, value} ->
             key == "Authorization" and value =~ "Bearer "
           end)

    assert Keyword.get(multipart_body, :image_type) == "message"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["msg_type"] == "image"
    assert Jason.decode!(body2["content"]) == %{"image_key" => "img_uploaded"}
  end

  test "progress payloads are ignored instead of being sent to feishu", %{pid: _pid} do
    Bus.publish_sync(:feishu_outbound, %{
      chat_id: "ou_123",
      content: "内部进度",
      metadata: %{"_progress" => true}
    })

    refute_receive {:http_post, _, _, _}, 100
  end

  test "ingest_event keeps structured normalized metadata for location messages", %{pid: pid} do
    payload = %{
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_sender"},
          "sender_type" => "user"
        },
        "message" => %{
          "message_id" => "om_loc",
          "chat_id" => "oc_group",
          "chat_type" => "group",
          "message_type" => "location",
          "content" =>
            Jason.encode!(%{
              "name" => "Shanghai Tower",
              "longitude" => "121.499",
              "latitude" => "31.239"
            })
        }
      }
    }

    assert :ok = GenServer.call(pid, {:ingest_event, payload})

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.channel == "feishu"
    assert inbound.content =~ "Shanghai Tower"
    assert inbound.metadata["message_type"] == "location"
    assert inbound.metadata["raw_content_json"]["name"] == "Shanghai Tower"
    assert inbound.metadata["normalized_content"]["card"]["longitude"] == "121.499"
  end

  test "ingest_event extracts post resources into metadata", %{pid: pid} do
    payload = %{
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_sender"},
          "sender_type" => "user"
        },
        "message" => %{
          "message_id" => "om_post",
          "chat_id" => "ou_sender",
          "chat_type" => "p2p",
          "message_type" => "post",
          "content" =>
            Jason.encode!(%{
              "zh_cn" => %{
                "title" => "Title",
                "content" => [
                  [
                    %{"tag" => "text", "text" => "hello"},
                    %{"tag" => "a", "text" => "link", "href" => "https://example.com"}
                  ],
                  [
                    %{"tag" => "img", "image_key" => "img_post_1"}
                  ]
                ]
              }
            })
        }
      }
    }

    assert :ok = GenServer.call(pid, {:ingest_event, payload})

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.metadata["message_type"] == "post"
    assert inbound.content =~ "Title"
    assert inbound.content =~ "link(https://example.com)"

    assert Enum.any?(
             inbound.metadata["resources"],
             &(&1["image_key"] == "img_post_1" and &1["message_id"] == "om_post")
           )

    assert Enum.any?(inbound.metadata["media"], &(&1["image_key"] == "img_post_1"))

    assert Enum.any?(
             inbound.metadata["media"],
             &String.starts_with?(&1["url"], "data:image/png;base64,")
           )
  end

  test "ingest_event hydrates image messages into media payloads", %{pid: pid} do
    payload = %{
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_sender"},
          "sender_type" => "user"
        },
        "message" => %{
          "message_id" => "om_img",
          "chat_id" => "ou_sender",
          "chat_type" => "p2p",
          "message_type" => "image",
          "content" => Jason.encode!(%{"image_key" => "img_abc"})
        }
      }
    }

    assert :ok = GenServer.call(pid, {:ingest_event, payload})

    assert_receive {:http_get, url, headers}
    assert url =~ "/im/v1/messages/om_img/resources/img_abc?type=image"

    assert Enum.any?(headers, fn {key, value} -> key == "Authorization" and value =~ "Bearer " end)

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.metadata["message_type"] == "image"

    assert [
             %{
               "type" => "image",
               "image_key" => "img_abc",
               "mime_type" => "image/png",
               "url" => data_url
             }
           ] =
             inbound.metadata["media"]

    assert String.starts_with?(data_url, "data:image/png;base64,")
  end

  test "ingest_event accepts top-level post content without locale wrapper", %{pid: pid} do
    payload = %{
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_sender"},
          "sender_type" => "user"
        },
        "message" => %{
          "message_id" => "om_post_flat",
          "chat_id" => "ou_sender",
          "chat_type" => "p2p",
          "message_type" => "post",
          "content" =>
            Jason.encode!(%{
              "title" => "",
              "content" => [
                [%{"tag" => "img", "image_key" => "img_flat_1"}],
                [%{"tag" => "text", "text" => "你好"}]
              ]
            })
        }
      }
    }

    assert :ok = GenServer.call(pid, {:ingest_event, payload})

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.metadata["message_type"] == "post"
    assert inbound.content =~ "你好"
    assert inbound.content =~ "[image]"

    assert Enum.any?(
             inbound.metadata["resources"],
             &(&1["image_key"] == "img_flat_1" and &1["message_id"] == "om_post_flat")
           )

    assert Enum.any?(inbound.metadata["media"], &(&1["image_key"] == "img_flat_1"))
  end
end
