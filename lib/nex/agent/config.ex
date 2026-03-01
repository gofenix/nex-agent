defmodule Nex.Agent.Config do
  @moduledoc """
  配置管理 - 从 ~/.nex/agent/config.json 加载配置
  """

  @default_config_path Path.join(System.get_env("HOME", "~"), ".nex/agent/config.json")

  defstruct provider: "openai",
            model: "gpt-4o",
            providers: %{},
            defaults: %{},
            gateway: %{},
            telegram: %{}

  @type t :: %__MODULE__{
          provider: String.t(),
          model: String.t(),
          providers: map(),
          defaults: map(),
          gateway: map(),
          telegram: map()
        }

  @doc """
  获取配置文件路径
  """
  @spec config_path() :: String.t()
  def config_path do
    Application.get_env(:nex_agent, :config_path, @default_config_path)
  end

  @doc """
  加载配置文件
  """
  @spec load() :: t()
  def load do
    path = config_path()

    if File.exists?(path) do
      case File.read!(path) |> Jason.decode() do
        {:ok, data} when is_map(data) ->
          %__MODULE__{
            provider: Map.get(data, "provider", "openai"),
            model: Map.get(data, "model", "gpt-4o"),
            providers: Map.get(data, "providers", default_providers()),
            defaults: Map.get(data, "defaults", default_defaults()),
            gateway: Map.get(data, "gateway", default_gateway()),
            telegram: Map.get(data, "telegram", default_telegram())
          }

        _ ->
          default()
      end
    else
      default()
    end
  end

  @doc """
  保存配置文件
  """
  @spec save(t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = config) do
    path = config_path()
    File.mkdir_p!(Path.dirname(path))

    data = %{
      "provider" => config.provider,
      "model" => config.model,
      "providers" => config.providers,
      "defaults" => config.defaults,
      "gateway" => config.gateway,
      "telegram" => config.telegram
    }

    File.write(path, Jason.encode!(data, pretty: true))
  end

  @doc """
  获取默认配置
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      provider: "openai",
      model: "gpt-4o",
      providers: default_providers(),
      defaults: default_defaults(),
      gateway: default_gateway(),
      telegram: default_telegram()
    }
  end

  @doc """
  获取 Telegram 配置
  """
  @spec telegram(t()) :: map()
  def telegram(%__MODULE__{} = config) do
    Map.merge(default_telegram(), config.telegram || %{})
  end

  @doc """
  Telegram 是否启用
  """
  @spec telegram_enabled?(t()) :: boolean()
  def telegram_enabled?(%__MODULE__{} = config) do
    config
    |> telegram()
    |> Map.get("enabled", false)
    |> Kernel.==(true)
  end

  @doc """
  获取 Telegram token
  """
  @spec telegram_token(t()) :: String.t() | nil
  def telegram_token(%__MODULE__{} = config) do
    case Map.get(telegram(config), "token") do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  @doc """
  获取 Telegram allow_from
  """
  @spec telegram_allow_from(t()) :: [String.t()]
  def telegram_allow_from(%__MODULE__{} = config) do
    case Map.get(telegram(config), "allow_from") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  @doc """
  Telegram 是否启用回复模式
  """
  @spec telegram_reply_to_message?(t()) :: boolean()
  def telegram_reply_to_message?(%__MODULE__{} = config) do
    config
    |> telegram()
    |> Map.get("reply_to_message", false)
    |> Kernel.==(true)
  end

  @doc """
  获取指定 provider 的 API key
  """
  @spec get_api_key(t(), String.t()) :: String.t() | nil
  def get_api_key(%__MODULE__{} = config, provider) do
    case Map.get(config.providers, provider) do
      %{"api_key" => key} when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  @doc """
  获取指定 provider 的 base URL
  """
  @spec get_base_url(t(), String.t()) :: String.t() | nil
  def get_base_url(%__MODULE__{} = config, provider) do
    case Map.get(config.providers, provider) do
      %{"base_url" => url} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  @doc """
  获取当前 provider 的 API key
  """
  @spec get_current_api_key(t()) :: String.t() | nil
  def get_current_api_key(%__MODULE__{provider: provider} = config) do
    get_api_key(config, provider)
  end

  @doc """
  获取当前 provider 的 base URL
  """
  @spec get_current_base_url(t()) :: String.t() | nil
  def get_current_base_url(%__MODULE__{provider: provider} = config) do
    get_base_url(config, provider)
  end

  @doc """
  更新配置
  """
  @spec set(t(), atom(), term()) :: t()
  def set(%__MODULE__{} = config, :provider, value) when is_binary(value) do
    %{config | provider: value}
  end

  def set(%__MODULE__{} = config, :model, value) when is_binary(value) do
    %{config | model: value}
  end

  def set(%__MODULE__{} = config, :api_key, {provider, key}) when is_binary(provider) do
    providers =
      Map.update(
        config.providers,
        provider,
        %{"api_key" => key, "base_url" => nil},
        fn p ->
          Map.put(p || %{}, "api_key", key)
        end
      )

    %{config | providers: providers}
  end

  def set(%__MODULE__{} = config, :telegram_enabled, value) when is_boolean(value) do
    %{config | telegram: Map.put(telegram(config), "enabled", value)}
  end

  def set(%__MODULE__{} = config, :telegram_token, value) when is_binary(value) do
    %{config | telegram: Map.put(telegram(config), "token", value)}
  end

  def set(%__MODULE__{} = config, :telegram_allow_from, value) when is_list(value) do
    allow_from =
      value
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{config | telegram: Map.put(telegram(config), "allow_from", allow_from)}
  end

  def set(%__MODULE__{} = config, :telegram_reply_to_message, value) when is_boolean(value) do
    %{config | telegram: Map.put(telegram(config), "reply_to_message", value)}
  end

  def set(%__MODULE__{} = config, :telegram_proxy, value)
      when is_binary(value) or is_nil(value) do
    %{config | telegram: Map.put(telegram(config), "proxy", value)}
  end

  def set(%__MODULE__{} = config, :base_url, {provider, url}) when is_binary(provider) do
    providers =
      Map.update(
        config.providers,
        provider,
        %{"api_key" => nil, "base_url" => url},
        fn p ->
          Map.put(p || %{}, "base_url", url)
        end
      )

    %{config | providers: providers}
  end

  @doc """
  验证配置是否有效
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{provider: provider} = config) do
    provider_valid? =
      case get_api_key(config, provider) do
        nil -> provider == "ollama"
        _ -> true
      end

    provider_valid? and telegram_valid?(config)
  end

  defp telegram_valid?(%__MODULE__{} = config) do
    if telegram_enabled?(config) do
      not is_nil(telegram_token(config))
    else
      true
    end
  end

  defp default_providers do
    %{
      "anthropic" => %{"api_key" => nil, "base_url" => nil},
      "openai" => %{"api_key" => nil, "base_url" => nil},
      "ollama" => %{"api_key" => nil, "base_url" => "http://localhost:11434"}
    }
  end

  defp default_defaults do
    %{
      "max_tokens" => 8192,
      "temperature" => 0.1,
      "max_iterations" => 40
    }
  end

  defp default_gateway do
    %{
      "host" => "0.0.0.0",
      "port" => 18790
    }
  end

  defp default_telegram do
    %{
      "enabled" => false,
      "token" => "",
      "allow_from" => [],
      "reply_to_message" => false,
      "proxy" => nil
    }
  end
end
