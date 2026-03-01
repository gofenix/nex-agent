defmodule Nex.Agent.Config do
  @moduledoc """
  配置管理 - 从 ~/.nex/agent/config.json 加载配置
  """

  @default_config_path Path.join(System.get_env("HOME", "~"), ".nex/agent/config.json")

  defstruct provider: "openai",
            model: "gpt-4o",
            providers: %{},
            defaults: %{},
            gateway: %{}

  @type t :: %__MODULE__{
          provider: String.t(),
          model: String.t(),
          providers: map(),
          defaults: map(),
          gateway: map()
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
            gateway: Map.get(data, "gateway", default_gateway())
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
      "gateway" => config.gateway
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
      gateway: default_gateway()
    }
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
    case get_api_key(config, provider) do
      nil -> provider == "ollama"
      _ -> true
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
end
