defmodule Nex.Agent.Feishu.Api do
  @moduledoc """
  Feishu Open API wrapper. Reuses token management from Nex.Agent.Channel.Feishu.
  """

  require Logger

  @feishu_api "https://open.feishu.cn/open-apis"
  @default_timeout_ms 30_000

  @spec get_tenant_token() :: {:ok, String.t()} | {:error, term()}
  def get_tenant_token do
    case Process.whereis(Nex.Agent.Channel.Feishu) do
      nil ->
        {:error, :feishu_channel_not_started}

      _pid ->
        case GenServer.call(Nex.Agent.Channel.Feishu, :get_tenant_access_token, 10_000) do
          {:ok, token, _state} -> {:ok, token}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec post(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(path, body, opts \\ []) do
    with {:ok, token} <- get_tenant_token() do
      url = @feishu_api <> path
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
      extra_headers = Keyword.get(opts, :headers, [])

      headers = [
        {"Authorization", "Bearer #{token}"},
        {"Content-Type", "application/json; charset=utf-8"}
        | extra_headers
      ]

      result =
        Req.post(url,
          json: body,
          headers: headers,
          receive_timeout: timeout,
          retry: false,
          finch: Req.Finch
        )

      handle_result(result)
    end
  end

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(path, opts \\ []) do
    with {:ok, token} <- get_tenant_token() do
      url = @feishu_api <> path
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
      extra_headers = Keyword.get(opts, :headers, [])
      params = Keyword.get(opts, :params, [])

      headers = [{"Authorization", "Bearer #{token}"} | extra_headers]

      result =
        Req.get(url,
          headers: headers,
          params: params,
          receive_timeout: timeout,
          retry: false,
          finch: Req.Finch
        )

      handle_result(result)
    end
  end

  @spec upload_file(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def upload_file(path, file_path, extra_params \\ %{}) do
    with {:ok, token} <- get_tenant_token(),
         {:ok, file_data} <- File.read(file_path) do
      filename = Path.basename(file_path)
      url = @feishu_api <> path

      form_data =
        extra_params
        |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
        |> Enum.concat([{"file", {"form", file_data, [{"filename", filename}]}}])

      headers = [{"Authorization", "Bearer #{token}"}]

      result =
        Req.post(url,
          multipart: form_data,
          headers: headers,
          receive_timeout: 60_000,
          retry: false,
          finch: Req.Finch
        )

      handle_result(result)
    end
  end

  @spec download_file(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def download_file(path, opts \\ []) do
    with {:ok, token} <- get_tenant_token() do
      url = @feishu_api <> path
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
      headers = [{"Authorization", "Bearer #{token}"}]

      result =
        Req.get(url, headers: headers, receive_timeout: timeout, retry: false, finch: Req.Finch)

      case result do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
        {:error, reason} -> {:error, {:request_failed, reason}}
      end
    end
  end

  @spec patch(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def patch(path, body, opts \\ []) do
    post(path, body, Keyword.put(opts, :method, :patch))
  end

  @spec put(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(path, body, opts \\ []) do
    with {:ok, token} <- get_tenant_token() do
      url = @feishu_api <> path
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
      extra_headers = Keyword.get(opts, :headers, [])

      headers = [
        {"Authorization", "Bearer #{token}"},
        {"Content-Type", "application/json; charset=utf-8"}
        | extra_headers
      ]

      result =
        Req.put(url,
          json: body,
          headers: headers,
          receive_timeout: timeout,
          retry: false,
          finch: Req.Finch
        )

      handle_result(result)
    end
  end

  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(path, opts \\ []) do
    with {:ok, token} <- get_tenant_token() do
      url = @feishu_api <> path
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
      extra_headers = Keyword.get(opts, :headers, [])
      headers = [{"Authorization", "Bearer #{token}"} | extra_headers]

      result =
        Req.delete(url,
          headers: headers,
          receive_timeout: timeout,
          retry: false,
          finch: Req.Finch
        )

      handle_result(result)
    end
  end

  defp handle_result({:ok, %{status: status} = response}) when status in 200..299 do
    body = Map.get(response, :body, response)
    normalize_response(body)
  end

  defp handle_result({:ok, %{status: status, body: body}}) do
    {:error, {:http_error, status, body}}
  end

  defp handle_result({:ok, body}) when is_map(body) do
    normalize_response(body)
  end

  defp handle_result({:error, reason}) do
    {:error, {:request_failed, reason}}
  end

  defp normalize_response(%{"code" => 0} = body), do: {:ok, body}

  defp normalize_response(%{"code" => code, "msg" => msg}),
    do: {:error, %{code: code, message: msg}}

  defp normalize_response(body), do: {:ok, body}
end
