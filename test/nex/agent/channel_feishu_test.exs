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

    config = %Config{Config.default() | feishu: %{"enabled" => false}}
    name = String.to_atom("feishu_test_#{System.unique_integer([:positive])}")
    pid = start_supervised!({Feishu, name: name, config: config, http_post_fun: http_post_fun})

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
    assert Enum.any?(inbound.metadata["resources"], &(&1["image_key"] == "img_post_1"))
  end
end
