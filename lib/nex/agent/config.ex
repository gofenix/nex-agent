defmodule Nex.Agent.Config do
  @moduledoc """
  Configuration management - loads config from ~/.nex/agent/config.json.
  """

  @default_config_path Path.join(System.get_env("HOME", "~"), ".nex/agent/config.json")

  defstruct provider: "openai",
            model: "gpt-4o",
            providers: %{},
            tools: %{},
            defaults: %{},
            gateway: %{},
            telegram: %{},
            feishu: %{},
            discord: %{},
            slack: %{},
            dingtalk: %{}

  @type t :: %__MODULE__{
          provider: String.t(),
          model: String.t(),
          providers: map(),
          tools: map(),
          defaults: map(),
          gateway: map(),
          telegram: map(),
          feishu: map(),
          discord: map(),
          slack: map(),
          dingtalk: map()
        }

  @doc """
  Get the default configuration file path.
  """
  @spec default_config_path() :: String.t()
  def default_config_path, do: @default_config_path

  @doc """
  Get the configuration file path.
  """
  @spec config_path(keyword()) :: String.t()
  def config_path(opts \\ []) when is_list(opts) do
    Keyword.get(opts, :config_path) ||
      Application.get_env(:nex_agent, :config_path, @default_config_path)
  end

  @doc """
  Load the configuration file.
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) when is_list(opts) do
    path = config_path(opts)

    if File.exists?(path) do
      case File.read!(path) |> Jason.decode() do
        {:ok, data} when is_map(data) ->
          %__MODULE__{
            provider: Map.get(data, "provider", "openai"),
            model: Map.get(data, "model", "gpt-4o"),
            providers: Map.merge(default_providers(), Map.get(data, "providers", %{})),
            tools: Map.get(data, "tools", %{}),
            defaults: Map.merge(default_defaults(), Map.get(data, "defaults", %{})),
            gateway: Map.merge(default_gateway(), Map.get(data, "gateway", %{})),
            telegram: Map.merge(default_telegram(), Map.get(data, "telegram", %{})),
            feishu: Map.merge(default_feishu(), Map.get(data, "feishu", %{})),
            discord: Map.merge(default_discord(), Map.get(data, "discord", %{})),
            slack: Map.merge(default_slack(), Map.get(data, "slack", %{})),
            dingtalk: Map.merge(default_dingtalk(), Map.get(data, "dingtalk", %{}))
          }

        _ ->
          default()
      end
    else
      default()
    end
  end

  @doc """
  Save the configuration file.
  """
  @spec save(t(), keyword()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = config, opts \\ []) when is_list(opts) do
    path = config_path(opts)
    File.mkdir_p!(Path.dirname(path))

    data = %{
      "provider" => config.provider,
      "model" => config.model,
      "providers" => config.providers,
      "tools" => config.tools,
      "defaults" => config.defaults,
      "gateway" => config.gateway,
      "telegram" => config.telegram,
      "feishu" => config.feishu,
      "discord" => config.discord,
      "slack" => config.slack,
      "dingtalk" => config.dingtalk
    }

    File.write(path, Jason.encode!(data, pretty: true))
  end

  @doc """
  Get the default configuration.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      provider: "openai",
      model: "gpt-4o",
      providers: default_providers(),
      defaults: default_defaults(),
      gateway: default_gateway(),
      telegram: default_telegram(),
      feishu: default_feishu(),
      discord: default_discord(),
      slack: default_slack(),
      dingtalk: default_dingtalk()
    }
  end

  @doc """
  Get the Telegram configuration.
  """
  @spec telegram(t()) :: map()
  def telegram(%__MODULE__{} = config) do
    Map.merge(default_telegram(), config.telegram || %{})
  end

  @doc """
  Get the Feishu configuration.
  """
  @spec feishu(t()) :: map()
  def feishu(%__MODULE__{} = config) do
    Map.merge(default_feishu(), config.feishu || %{})
  end

  @doc """
  Whether Telegram is enabled.
  """
  @spec telegram_enabled?(t()) :: boolean()
  def telegram_enabled?(%__MODULE__{} = config) do
    config
    |> telegram()
    |> Map.get("enabled", false)
    |> Kernel.==(true)
  end

  @doc """
  Get the Telegram token.
  """
  @spec telegram_token(t()) :: String.t() | nil
  def telegram_token(%__MODULE__{} = config) do
    case Map.get(telegram(config), "token") do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  @doc """
  Get the Telegram `allow_from` list.
  """
  @spec telegram_allow_from(t()) :: [String.t()]
  def telegram_allow_from(%__MODULE__{} = config) do
    case Map.get(telegram(config), "allow_from") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  @doc """
  Whether Telegram reply mode is enabled.
  """
  @spec telegram_reply_to_message?(t()) :: boolean()
  def telegram_reply_to_message?(%__MODULE__{} = config) do
    config
    |> telegram()
    |> Map.get("reply_to_message", false)
    |> Kernel.==(true)
  end

  @doc """
  Whether Feishu is enabled.
  """
  @spec feishu_enabled?(t()) :: boolean()
  def feishu_enabled?(%__MODULE__{} = config) do
    config
    |> feishu()
    |> Map.get("enabled", false)
    |> Kernel.==(true)
  end

  @doc """
  Get the Feishu `app_id`.
  """
  @spec feishu_app_id(t()) :: String.t() | nil
  def feishu_app_id(%__MODULE__{} = config) do
    case Map.get(feishu(config), "app_id") do
      app_id when is_binary(app_id) and app_id != "" -> app_id
      _ -> nil
    end
  end

  @doc """
  Get the Feishu `app_secret`.
  """
  @spec feishu_app_secret(t()) :: String.t() | nil
  def feishu_app_secret(%__MODULE__{} = config) do
    case Map.get(feishu(config), "app_secret") do
      app_secret when is_binary(app_secret) and app_secret != "" -> app_secret
      _ -> nil
    end
  end

  @doc """
  Get the Feishu `allow_from` list.
  """
  @spec feishu_allow_from(t()) :: [String.t()]
  def feishu_allow_from(%__MODULE__{} = config) do
    case Map.get(feishu(config), "allow_from") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  @doc """
  Get the Feishu reaction emoji.
  """
  @spec feishu_react_emoji(t()) :: String.t()
  def feishu_react_emoji(%__MODULE__{} = config) do
    case Map.get(feishu(config), "react_emoji") do
      emoji when is_binary(emoji) and emoji != "" -> emoji
      _ -> "THUMBSUP"
    end
  end

  @doc """
  Get the Feishu `encrypt_key`.
  """
  @spec feishu_encrypt_key(t()) :: String.t() | nil
  def feishu_encrypt_key(%__MODULE__{} = config) do
    case Map.get(feishu(config), "encrypt_key") do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  @doc """
  Get the Feishu `verification_token`.
  """
  @spec feishu_verification_token(t()) :: String.t() | nil
  def feishu_verification_token(%__MODULE__{} = config) do
    case Map.get(feishu(config), "verification_token") do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  @doc """
  Get the API key for the specified provider.
  """
  @spec get_api_key(t(), String.t()) :: String.t() | nil
  def get_api_key(%__MODULE__{} = config, provider) do
    case Map.get(config.providers, provider) do
      %{"api_key" => key} when is_binary(key) and key != "" -> key
      _ -> provider_env_api_key(provider)
    end
  end

  @doc """
  Get the base URL for the specified provider.
  """
  @spec get_base_url(t(), String.t()) :: String.t() | nil
  def get_base_url(%__MODULE__{} = config, provider) do
    case Map.get(config.providers, provider) do
      %{"base_url" => url} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  @doc """
  Get the API key for the current provider.
  """
  @spec get_current_api_key(t()) :: String.t() | nil
  def get_current_api_key(%__MODULE__{provider: provider} = config) do
    get_api_key(config, provider)
  end

  @doc """
  Get the base URL for the current provider.
  """
  @spec get_current_base_url(t()) :: String.t() | nil
  def get_current_base_url(%__MODULE__{provider: provider} = config) do
    get_base_url(config, provider)
  end

  @doc """
  Get tool configuration value.
  Supports reading from:
  - Direct value in config.json: "brave_api_key": "xxx"
  - Environment variable: "brave_api_key": {"env": "BRAVE_API_KEY"}
  """
  @spec get_tool_config(t(), String.t()) :: String.t() | nil
  def get_tool_config(%__MODULE__{tools: tools}, key) do
    case Map.get(tools, key) do
      nil ->
        nil

      %{"env" => env_var} when is_binary(env_var) ->
        System.get_env(env_var)

      value when is_binary(value) ->
        value

      _ ->
        nil
    end
  end

  @doc """
  Update the configuration.
  """
  @spec set(t(), atom(), term()) :: t()
  def set(%__MODULE__{} = config, :provider, value) when is_binary(value) do
    %{config | provider: value}
  end

  def set(%__MODULE__{} = config, :model, value) when is_binary(value) do
    %{config | model: value}
  end

  def set(%__MODULE__{} = config, :default_workspace, value) when is_binary(value) do
    defaults = Map.merge(default_defaults(), config.defaults || %{})
    %{config | defaults: Map.put(defaults, "workspace", value)}
  end

  def set(%__MODULE__{} = config, :gateway_port, value) when is_integer(value) and value > 0 do
    gateway = Map.merge(default_gateway(), config.gateway || %{})
    %{config | gateway: Map.put(gateway, "port", value)}
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

  def set(%__MODULE__{} = config, :feishu_enabled, value) when is_boolean(value) do
    %{config | feishu: Map.put(feishu(config), "enabled", value)}
  end

  def set(%__MODULE__{} = config, :feishu_app_id, value) when is_binary(value) do
    %{config | feishu: Map.put(feishu(config), "app_id", value)}
  end

  def set(%__MODULE__{} = config, :feishu_app_secret, value) when is_binary(value) do
    %{config | feishu: Map.put(feishu(config), "app_secret", value)}
  end

  def set(%__MODULE__{} = config, :feishu_encrypt_key, value) when is_binary(value) do
    %{config | feishu: Map.put(feishu(config), "encrypt_key", value)}
  end

  def set(%__MODULE__{} = config, :feishu_verification_token, value) when is_binary(value) do
    %{config | feishu: Map.put(feishu(config), "verification_token", value)}
  end

  def set(%__MODULE__{} = config, :feishu_allow_from, value) when is_list(value) do
    allow_from =
      value
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{config | feishu: Map.put(feishu(config), "allow_from", allow_from)}
  end

  def set(%__MODULE__{} = config, :feishu_react_emoji, value) when is_binary(value) do
    %{config | feishu: Map.put(feishu(config), "react_emoji", value)}
  end

  # Discord setters

  def set(%__MODULE__{} = config, :discord_enabled, value) when is_boolean(value) do
    %{config | discord: Map.put(discord(config), "enabled", value)}
  end

  def set(%__MODULE__{} = config, :discord_token, value) when is_binary(value) do
    %{config | discord: Map.put(discord(config), "token", value)}
  end

  def set(%__MODULE__{} = config, :discord_allow_from, value) when is_list(value) do
    allow_from =
      value
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{config | discord: Map.put(discord(config), "allow_from", allow_from)}
  end

  # Slack setters

  def set(%__MODULE__{} = config, :slack_enabled, value) when is_boolean(value) do
    %{config | slack: Map.put(slack(config), "enabled", value)}
  end

  def set(%__MODULE__{} = config, :slack_app_token, value) when is_binary(value) do
    %{config | slack: Map.put(slack(config), "app_token", value)}
  end

  def set(%__MODULE__{} = config, :slack_bot_token, value) when is_binary(value) do
    %{config | slack: Map.put(slack(config), "bot_token", value)}
  end

  def set(%__MODULE__{} = config, :slack_allow_from, value) when is_list(value) do
    allow_from =
      value
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{config | slack: Map.put(slack(config), "allow_from", allow_from)}
  end

  # DingTalk setters

  def set(%__MODULE__{} = config, :dingtalk_enabled, value) when is_boolean(value) do
    %{config | dingtalk: Map.put(dingtalk(config), "enabled", value)}
  end

  def set(%__MODULE__{} = config, :dingtalk_app_key, value) when is_binary(value) do
    %{config | dingtalk: Map.put(dingtalk(config), "app_key", value)}
  end

  def set(%__MODULE__{} = config, :dingtalk_app_secret, value) when is_binary(value) do
    %{config | dingtalk: Map.put(dingtalk(config), "app_secret", value)}
  end

  def set(%__MODULE__{} = config, :dingtalk_robot_code, value) when is_binary(value) do
    %{config | dingtalk: Map.put(dingtalk(config), "robot_code", value)}
  end

  def set(%__MODULE__{} = config, :dingtalk_allow_from, value) when is_list(value) do
    allow_from =
      value
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{config | dingtalk: Map.put(dingtalk(config), "allow_from", allow_from)}
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
  Get the Discord configuration.
  """
  @spec discord(t()) :: map()
  def discord(%__MODULE__{} = config) do
    Map.merge(default_discord(), config.discord || %{})
  end

  @doc """
  Whether Discord is enabled.
  """
  @spec discord_enabled?(t()) :: boolean()
  def discord_enabled?(%__MODULE__{} = config) do
    config |> discord() |> Map.get("enabled", false) |> Kernel.==(true)
  end

  @doc """
  Get the Discord `allow_from` list.
  """
  @spec discord_allow_from(t()) :: [String.t()]
  def discord_allow_from(%__MODULE__{} = config) do
    case Map.get(discord(config), "allow_from") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  @doc """
  Get the Slack configuration.
  """
  @spec slack(t()) :: map()
  def slack(%__MODULE__{} = config) do
    Map.merge(default_slack(), config.slack || %{})
  end

  @doc """
  Whether Slack is enabled.
  """
  @spec slack_enabled?(t()) :: boolean()
  def slack_enabled?(%__MODULE__{} = config) do
    config |> slack() |> Map.get("enabled", false) |> Kernel.==(true)
  end

  @doc """
  Get the Slack `allow_from` list.
  """
  @spec slack_allow_from(t()) :: [String.t()]
  def slack_allow_from(%__MODULE__{} = config) do
    case Map.get(slack(config), "allow_from") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  @doc """
  Get the DingTalk configuration.
  """
  @spec dingtalk(t()) :: map()
  def dingtalk(%__MODULE__{} = config) do
    Map.merge(default_dingtalk(), config.dingtalk || %{})
  end

  @doc """
  Whether DingTalk is enabled.
  """
  @spec dingtalk_enabled?(t()) :: boolean()
  def dingtalk_enabled?(%__MODULE__{} = config) do
    config |> dingtalk() |> Map.get("enabled", false) |> Kernel.==(true)
  end

  @doc """
  Get the DingTalk `allow_from` list.
  """
  @spec dingtalk_allow_from(t()) :: [String.t()]
  def dingtalk_allow_from(%__MODULE__{} = config) do
    case Map.get(dingtalk(config), "allow_from") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  @doc """
  Get the maximum iteration count.
  """
  @spec get_max_iterations(t()) :: pos_integer()
  def get_max_iterations(%__MODULE__{} = config) do
    case Map.get(config.defaults || %{}, "max_iterations") do
      n when is_integer(n) and n > 0 -> n
      _ -> 40
    end
  end

  @doc """
  Get the configured default workspace, if any.
  """
  @spec configured_workspace(t()) :: String.t() | nil
  def configured_workspace(%__MODULE__{} = config) do
    case Map.get(config.defaults || %{}, "workspace") do
      workspace when is_binary(workspace) and workspace != "" -> workspace
      _ -> nil
    end
  end

  @doc """
  Get the configured gateway port.
  """
  @spec gateway_port(t()) :: pos_integer()
  def gateway_port(%__MODULE__{} = config) do
    case Map.get(config.gateway || %{}, "port") do
      port when is_integer(port) and port > 0 ->
        port

      port when is_binary(port) ->
        case Integer.parse(port) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> 18_790
        end

      _ ->
        18_790
    end
  end

  @doc """
  Convert provider string to atom safely.
  Returns :openai for unknown providers to prevent atom leaks.
  """
  @spec provider_to_atom(String.t()) :: atom()
  def provider_to_atom(provider) when is_binary(provider) do
    case provider do
      "anthropic" -> :anthropic
      "openai" -> :openai
      "openrouter" -> :openrouter
      "ollama" -> :ollama
      _ -> :openai
    end
  end

  def provider_to_atom(provider) when is_atom(provider), do: provider

  @doc """
  Validate whether the configuration is valid.
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{provider: provider} = config) do
    provider_valid? =
      case get_api_key(config, provider) do
        nil -> provider == "ollama"
        _ -> true
      end

    provider_valid? and telegram_valid?(config) and feishu_valid?(config) and
      discord_valid?(config) and slack_valid?(config) and dingtalk_valid?(config)
  end

  defp provider_env_api_key("anthropic"), do: System.get_env("ANTHROPIC_API_KEY")
  defp provider_env_api_key("openai"), do: System.get_env("OPENAI_API_KEY")
  defp provider_env_api_key("ollama"), do: nil
  defp provider_env_api_key(_), do: nil

  defp telegram_valid?(%__MODULE__{} = config) do
    if telegram_enabled?(config) do
      not is_nil(telegram_token(config))
    else
      true
    end
  end

  defp feishu_valid?(%__MODULE__{} = config) do
    if feishu_enabled?(config) do
      not is_nil(feishu_app_id(config)) and not is_nil(feishu_app_secret(config))
    else
      true
    end
  end

  defp discord_valid?(%__MODULE__{} = config) do
    if discord_enabled?(config) do
      token = Map.get(discord(config), "token", "")
      is_binary(token) and token != ""
    else
      true
    end
  end

  defp slack_valid?(%__MODULE__{} = config) do
    if slack_enabled?(config) do
      slack_cfg = slack(config)
      app_token = Map.get(slack_cfg, "app_token", "")
      bot_token = Map.get(slack_cfg, "bot_token", "")
      is_binary(app_token) and app_token != "" and is_binary(bot_token) and bot_token != ""
    else
      true
    end
  end

  defp dingtalk_valid?(%__MODULE__{} = config) do
    if dingtalk_enabled?(config) do
      dt = dingtalk(config)
      app_key = Map.get(dt, "app_key", "")
      app_secret = Map.get(dt, "app_secret", "")
      is_binary(app_key) and app_key != "" and is_binary(app_secret) and app_secret != ""
    else
      true
    end
  end

  defp default_providers do
    %{
      "anthropic" => %{"api_key" => nil, "base_url" => nil},
      "openai" => %{"api_key" => nil, "base_url" => nil},
      "openrouter" => %{"api_key" => nil, "base_url" => "https://openrouter.ai/api/v1"},
      "ollama" => %{"api_key" => nil, "base_url" => "http://localhost:11434"}
    }
  end

  defp default_defaults do
    %{
      "max_iterations" => 40,
      "workspace" => nil
    }
  end

  defp default_gateway do
    %{
      "port" => 18_790
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

  defp default_feishu do
    %{
      "enabled" => false,
      "app_id" => "",
      "app_secret" => "",
      "encrypt_key" => "",
      "verification_token" => "",
      "allow_from" => [],
      "react_emoji" => "THUMBSUP"
    }
  end

  defp default_discord do
    %{
      "enabled" => false,
      "token" => "",
      "allow_from" => [],
      "guild_id" => nil
    }
  end

  defp default_slack do
    %{
      "enabled" => false,
      "app_token" => "",
      "bot_token" => "",
      "allow_from" => []
    }
  end

  defp default_dingtalk do
    %{
      "enabled" => false,
      "app_key" => "",
      "app_secret" => "",
      "robot_code" => "",
      "allow_from" => []
    }
  end
end
