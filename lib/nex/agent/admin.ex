defmodule Nex.Agent.Admin do
  @moduledoc false

  require Logger

  alias Nex.Agent.{
    Admin.Event,
    Audit,
    Bus,
    CodeUpgrade,
    Config,
    Cron,
    Evolution,
    Gateway,
    Heartbeat,
    Session,
    SessionManager,
    Skills,
    Tasks,
    UpgradeManager,
    Workspace
  }

  alias Nex.Agent.Tool.{CustomTools, Registry}
  alias Nex.SkillRuntime.Store

  @event_topic :admin_events
  @max_preview_lines 120

  @spec subscribe_events(pid()) :: :ok
  def subscribe_events(pid \\ self()) do
    if Process.whereis(Bus) do
      Bus.subscribe(@event_topic, pid)
    else
      :ok
    end
  end

  @spec publish_event(Event.t() | map()) :: :ok
  def publish_event(%Event{} = event) do
    if Process.whereis(Bus) do
      Bus.publish(@event_topic, Event.to_map(event))
    end

    :ok
  end

  def publish_event(event) when is_map(event) do
    event
    |> normalize_event()
    |> publish_event()
  end

  @spec publish(String.t(), String.t(), String.t(), map()) :: :ok
  def publish(topic, kind, summary, payload \\ %{}) do
    topic
    |> Event.new(kind, summary, payload)
    |> publish_event()
  end

  @spec publish_audit_entry(map()) :: :ok
  def publish_audit_entry(entry) when is_map(entry) do
    entry
    |> Event.from_audit_entry()
    |> publish_event()
  end

  @spec recent_events(keyword()) :: [map()]
  def recent_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Audit.recent(Keyword.put(workspace_opts(opts), :limit, limit))
    |> Enum.map(&Event.from_audit_entry/1)
    |> Enum.map(&Event.to_map/1)
  end

  @spec overview_state(keyword()) :: map()
  def overview_state(opts \\ []) do
    %{
      runtime: runtime_state(opts),
      recent_events: recent_events(limit: 12, workspace: workspace(opts)),
      skills: skills_summary(opts),
      tasks: tasks_summary(opts),
      recent_sessions: Enum.take(list_sessions(opts), 6),
      code: code_summary(opts)
    }
  end

  @spec evolution_state(keyword()) :: map()
  def evolution_state(opts \\ []) do
    workspace = workspace(opts)

    %{
      workspace: workspace,
      recent_events:
        Audit.recent(Keyword.put(workspace_opts(opts), :limit, 60))
        |> Enum.filter(&String.starts_with?(Map.get(&1, "event", ""), "evolution.")),
      soul_preview: file_preview(Path.join(workspace, "SOUL.md")),
      user_preview: file_preview(Path.join(workspace, "USER.md"), 40),
      memory_preview:
        file_preview(Path.join(Workspace.memory_dir(workspace: workspace), "MEMORY.md")),
      layers: evolution_layers(opts)
    }
  end

  @spec skills_state(keyword()) :: map()
  def skills_state(opts \\ []) do
    workspace = workspace(opts)
    runtime_opts = workspace_opts(opts)

    %{
      workspace: workspace,
      local_skills: Skills.list(runtime_opts),
      runtime_packages: Store.load_skill_records(runtime_opts),
      runtime_catalog: Store.load_catalog_records(runtime_opts),
      lineage: Store.load_lineage_records(runtime_opts) |> Enum.take(-50) |> Enum.reverse(),
      recent_runs: list_runtime_runs(workspace) |> Enum.take(20),
      tools: tool_inventory(),
      skill_runtime_config:
        Config.load(config_path: Keyword.get(opts, :config_path)) |> Config.skill_runtime()
    }
  end

  @spec memory_state(keyword()) :: map()
  def memory_state(opts \\ []) do
    workspace = workspace(opts)
    memory_dir = Workspace.memory_dir(workspace: workspace)

    %{
      workspace: workspace,
      soul_preview: file_preview(Path.join(workspace, "SOUL.md"), 40),
      memory_preview: file_preview(Path.join(memory_dir, "MEMORY.md"), 80),
      user_preview: file_preview(Path.join(workspace, "USER.md"), 60),
      memory_bytes: file_size(Path.join(memory_dir, "MEMORY.md")),
      recent_events:
        Audit.recent(Keyword.put(workspace_opts(opts), :limit, 20))
        |> Enum.filter(fn entry ->
          event = Map.get(entry, "event", "")
          String.starts_with?(event, "memory.") or String.starts_with?(event, "evolution.memory_")
        end)
    }
  end

  @spec sessions_state(keyword()) :: map()
  def sessions_state(opts \\ []) do
    sessions = list_sessions(opts)
    selected_key = Keyword.get(opts, :session_key) || session_key_from_list(sessions)
    selected = if selected_key, do: session_detail(selected_key, opts), else: nil

    %{
      sessions: sessions,
      selected_session: selected
    }
  end

  @spec tasks_state(keyword()) :: map()
  def tasks_state(opts \\ []) do
    %{
      tasks: Tasks.list(workspace_opts(opts)),
      summary: tasks_summary(opts),
      cron_jobs: list_cron_jobs(opts),
      cron_status: cron_status(opts)
    }
  end

  @spec runtime_state(keyword()) :: map()
  def runtime_state(opts \\ []) do
    workspace = workspace(opts)

    gateway =
      if Process.whereis(Gateway) do
        Gateway.status()
      else
        %{
          status: :stopped,
          started_at: nil,
          config: %{},
          services: %{}
        }
      end

    heartbeat =
      if Process.whereis(Heartbeat) do
        Heartbeat.status()
      else
        %{
          enabled: false,
          running: false,
          interval: nil,
          recent_history: [],
          services_health: %{}
        }
      end

    %{
      workspace: workspace,
      gateway: gateway,
      heartbeat: heartbeat,
      directories:
        Workspace.known_dirs()
        |> Enum.map(fn name ->
          path = Workspace.dir(name, workspace: workspace)
          %{name: name, path: path, exists: File.dir?(path)}
        end)
    }
  end

  @spec code_state(keyword()) :: map()
  def code_state(opts \\ []) do
    modules = code_modules()
    selected_name = Keyword.get(opts, :module) || List.first(modules)
    selected_module = if selected_name, do: resolve_module(selected_name), else: nil

    %{
      modules: modules,
      selected_module: selected_name,
      current_source: source_for(selected_module),
      current_source_preview: source_preview_for(selected_module),
      versions: versions_for(selected_module),
      recent_events:
        Audit.recent(Keyword.put(workspace_opts(opts), :limit, 30))
        |> Enum.filter(&String.starts_with?(Map.get(&1, "event", ""), "code."))
    }
  end

  @spec session_detail(String.t(), keyword()) :: map() | nil
  def session_detail(session_key, opts \\ []) when is_binary(session_key) do
    case load_session(session_key, opts) do
      nil ->
        nil

      %Session{} = session ->
        messages = session.messages
        unreviewed = max(length(messages) - session.last_consolidated, 0)

        %{
          key: session.key,
          created_at: session.created_at,
          updated_at: session.updated_at,
          total_messages: length(messages),
          last_reviewed_message_count: session.last_consolidated,
          unreviewed_messages: unreviewed,
          last_prompt: get_in(session.metadata || %{}, ["runtime_evolution", "last_prompt"]),
          messages:
            messages
            |> Enum.take(-24)
            |> Enum.map(fn msg ->
              %{
                "role" => Map.get(msg, "role"),
                "content" => truncate_text(Map.get(msg, "content"), 400),
                "timestamp" => Map.get(msg, "timestamp")
              }
            end)
        }
    end
  end

  @spec run_evolution_cycle(keyword()) :: {:ok, map()} | {:error, term()}
  def run_evolution_cycle(opts \\ []) do
    Evolution.run_evolution_cycle(
      opts
      |> Keyword.put_new(:workspace, workspace(opts))
      |> Keyword.put_new(:trigger, :manual)
      |> Keyword.merge(current_llm_opts(opts))
    )
  end

  @spec consolidate_memory(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def consolidate_memory(session_key, opts \\ []) when is_binary(session_key) do
    ctx =
      current_llm_opts(opts)
      |> Keyword.put(:workspace, workspace(opts))
      |> Enum.into(%{})

    result =
      Nex.Agent.Tool.MemoryConsolidate.execute(%{"session_key" => session_key}, ctx)

    case result do
      {:ok, payload} ->
        Audit.append(
          "memory.consolidated",
          Map.merge(payload, %{"session_key" => session_key}),
          workspace_opts(opts)
        )

        {:ok, payload}

      other ->
        other
    end
  end

  @spec reset_session(String.t(), keyword()) :: :ok | {:error, term()}
  def reset_session(session_key, opts \\ []) when is_binary(session_key) do
    session =
      case load_session(session_key, opts) do
        %Session{} = existing -> Session.clear(existing)
        nil -> Session.new(session_key)
      end

    with :ok <- Session.save(session, workspace_opts(opts)) do
      SessionManager.invalidate(session_key, workspace_opts(opts))

      Audit.append(
        "session.reset",
        %{"session_key" => session_key},
        workspace_opts(opts)
      )

      :ok
    end
  end

  @spec enable_cron_job(String.t(), boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def enable_cron_job(job_id, enabled, opts \\ []) do
    Cron.enable_job(job_id, enabled, workspace_opts(opts))
  end

  @spec run_cron_job(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_cron_job(job_id, opts \\ []) do
    Cron.run_job(job_id, workspace_opts(opts))
  end

  @spec start_gateway() :: :ok | {:error, term()}
  def start_gateway do
    result = Gateway.start()

    if result == :ok do
      Audit.append("runtime.gateway_started", %{}, [])
    end

    result
  end

  @spec stop_gateway() :: :ok
  def stop_gateway do
    result = Gateway.stop()
    Audit.append("runtime.gateway_stopped", %{}, [])
    result
  end

  @spec code_preview(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def code_preview(module_name, code)
      when is_binary(module_name) and is_binary(code) and code != "" do
    case resolve_module(module_name) do
      nil ->
        {:error, "Unknown module: #{module_name}"}

      module ->
        {:ok,
         %{
           module: module_name,
           diff: CodeUpgrade.diff(module, code),
           current_source: source_preview_for(module)
         }}
    end
  end

  def code_preview(_module_name, _code), do: {:error, "module and code are required"}

  @spec hot_upgrade_code(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def hot_upgrade_code(module_name, code, reason, opts \\ [])
      when is_binary(module_name) and is_binary(code) and is_binary(reason) do
    case resolve_module(module_name) do
      nil ->
        {:error, "Unknown module: #{module_name}"}

      module ->
        UpgradeManager.hot_upgrade(module, code,
          reason: reason,
          workspace: workspace(opts)
        )
    end
  end

  @spec rollback_code(String.t(), String.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def rollback_code(module_name, version_id \\ nil, opts \\ [])

  def rollback_code(module_name, version_id, opts) when is_binary(module_name) do
    case resolve_module(module_name) do
      nil ->
        {:error, "Unknown module: #{module_name}"}

      module ->
        result =
          if present?(version_id) do
            CodeUpgrade.rollback(module, version_id)
          else
            CodeUpgrade.rollback(module)
          end

        if result == :ok do
          Audit.append(
            "code.rollback",
            %{
              "module" => module_name,
              "version_id" => version_id,
              "workspace" => workspace(opts)
            },
            workspace_opts(opts)
          )
        end

        result
    end
  end

  defp normalize_event(%{"topic" => topic, "kind" => kind, "summary" => summary} = event) do
    Event.new(topic, kind, summary, Map.get(event, "payload", %{}))
  end

  defp normalize_event(%{topic: topic, kind: kind, summary: summary} = event) do
    Event.new(topic, kind, summary, Map.get(event, :payload, %{}))
  end

  defp skills_summary(opts) do
    runtime_opts = workspace_opts(opts)
    tools = tool_summary()

    %{
      local_count: length(Skills.list(runtime_opts)),
      runtime_package_count: length(Store.load_skill_records(runtime_opts)),
      lineage_events: length(Store.load_lineage_records(runtime_opts)),
      recent_runs: length(list_runtime_runs(workspace(opts))),
      builtin_tools: tools.builtin_count,
      custom_tools: tools.custom_count
    }
  end

  defp tasks_summary(opts) do
    summary = Tasks.summary("all", workspace_opts(opts))

    %{
      open: summary["open"],
      completed: summary["completed"],
      upcoming: Enum.take(summary["upcoming"] || [], 8),
      recent: Enum.take(summary["recent"] || [], 8)
    }
  end

  defp code_summary(opts) do
    %{
      modules: length(code_modules()),
      recent_events:
        Audit.recent(Keyword.put(workspace_opts(opts), :limit, 8))
        |> Enum.filter(&String.starts_with?(Map.get(&1, "event", ""), "code."))
    }
  end

  defp evolution_layers(opts) do
    workspace = workspace(opts)
    skills = skills_summary(opts)
    tools = tool_summary()
    code = code_summary(opts)

    [
      %{
        key: "SOUL",
        href: "/memory",
        summary: "身份、价值观与长期原则",
        detail: preview_summary(file_preview(Path.join(workspace, "SOUL.md"), 18), "(SOUL 暂无内容)")
      },
      %{
        key: "USER",
        href: "/memory",
        summary: "用户画像、协作风格与长期偏好",
        detail: preview_summary(file_preview(Path.join(workspace, "USER.md"), 18), "(USER 暂无内容)")
      },
      %{
        key: "MEMORY",
        href: "/memory",
        summary: "项目事实、长期经验与上下文",
        detail:
          "#{length(Evolution.read_signals(workspace_opts(opts)))} 个 pending signals · #{file_size(Path.join(Workspace.memory_dir(workspace: workspace), "MEMORY.md"))} bytes"
      },
      %{
        key: "SKILL",
        href: "/skills",
        summary: "可复用的方法、流程与谱系",
        detail:
          "#{skills.local_count} 本地 skills · #{skills.runtime_package_count} runtime packages"
      },
      %{
        key: "TOOL",
        href: "/skills",
        summary: "确定性能力与可调用扩展",
        detail: "#{tools.builtin_count} builtin tools · #{tools.custom_count} custom tools"
      },
      %{
        key: "CODE",
        href: "/code",
        summary: "底层实现升级、diff 与回滚",
        detail: "#{code.modules} 个模块可热更 · #{length(code.recent_events)} 条最近 code events"
      }
    ]
  end

  defp tool_summary do
    inventory = tool_inventory()

    %{
      builtin_count: length(inventory.builtin),
      custom_count: length(inventory.custom)
    }
  end

  defp tool_inventory do
    custom = CustomTools.list()
    custom_names = MapSet.new(Enum.map(custom, &Map.get(&1, "name")))

    builtin_names =
      if Process.whereis(Registry) do
        Registry.list()
      else
        Registry.builtin_names()
      end

    builtin =
      builtin_names
      |> Enum.reject(&MapSet.member?(custom_names, &1))
      |> Enum.sort()
      |> Enum.map(fn name ->
        module =
          if Process.whereis(Registry) do
            Registry.get(name)
          end

        %{
          "name" => name,
          "description" => tool_description(module),
          "layers" => tool_layers(module)
        }
      end)

    %{
      builtin: builtin,
      custom:
        Enum.map(custom, fn tool ->
          %{
            "name" => tool["name"],
            "description" => tool["description"],
            "module" => tool["module"],
            "origin" => tool["origin"],
            "layers" => ["tool"]
          }
        end)
    }
  end

  defp tool_description(module) when is_atom(module) do
    if function_exported?(module, :description, 0), do: module.description(), else: ""
  end

  defp tool_description(_), do: ""

  defp tool_layers(module) when is_atom(module) do
    if function_exported?(module, :name, 0) do
      case module.name() do
        "soul_update" -> ["soul"]
        "user_update" -> ["user"]
        "memory_consolidate" -> ["memory"]
        "memory_status" -> ["memory"]
        "memory_rebuild" -> ["memory"]
        "memory_write" -> ["memory"]
        "skill_discover" -> ["skill"]
        "skill_get" -> ["skill"]
        "skill_capture" -> ["skill"]
        "skill_import" -> ["skill"]
        "skill_sync" -> ["skill"]
        "tool_create" -> ["tool"]
        "tool_list" -> ["tool"]
        "tool_delete" -> ["tool"]
        "reflect" -> ["code"]
        "upgrade_code" -> ["code"]
        _ -> ["tool"]
      end
    else
      ["tool"]
    end
  end

  defp tool_layers(_), do: ["tool"]

  defp list_sessions(opts) do
    session_files =
      opts
      |> workspace_opts()
      |> Session.sessions_dir()
      |> Path.join("*/messages.jsonl")
      |> Path.wildcard()

    session_files
    |> Enum.map(fn path ->
      session = load_session_from_path(path)

      if session do
        last_message =
          case List.last(session.messages) do
            %{} = message -> Map.get(message, "content")
            _ -> nil
          end

        %{
          key: session.key,
          created_at: session.created_at,
          updated_at: session.updated_at,
          total_messages: length(session.messages),
          last_message: truncate_text(last_message, 120)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&to_naive(&1.updated_at), {:desc, NaiveDateTime})
  end

  defp session_key_from_list([first | _]), do: first.key
  defp session_key_from_list([]), do: nil

  defp list_cron_jobs(opts) do
    if Process.whereis(Cron) do
      Cron.list_jobs(workspace_opts(opts))
    else
      opts
      |> workspace_opts()
      |> Workspace.tasks_dir()
      |> Path.join("cron_jobs.json")
      |> read_json_array()
    end
  end

  defp cron_status(opts) do
    if Process.whereis(Cron) do
      Cron.status(workspace_opts(opts))
    else
      jobs = list_cron_jobs(opts)

      %{
        total: length(jobs),
        enabled: Enum.count(jobs, &truthy(Map.get(&1, "enabled"))),
        disabled: Enum.count(jobs, &(not truthy(Map.get(&1, "enabled")))),
        next_wakeup: nil,
        next_wakeup_in: nil
      }
    end
  end

  defp list_runtime_runs(workspace) do
    workspace
    |> Path.join("skill_runtime/runs/*.jsonl")
    |> Path.wildcard()
    |> Enum.map(&runtime_run_summary/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&(&1.inserted_at || ""), :desc)
  end

  defp code_modules do
    CodeUpgrade.list_upgradable_modules()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.map(&String.replace_prefix(&1, "Elixir.", ""))
    |> Enum.sort()
  end

  defp versions_for(nil), do: []

  defp versions_for(module) do
    CodeUpgrade.list_versions(module)
    |> Enum.sort_by(&Map.get(&1, :timestamp), :desc)
  end

  defp source_for(nil), do: ""

  defp source_for(module) do
    case CodeUpgrade.get_source(module) do
      {:ok, source} -> source
      {:error, _} -> ""
    end
  end

  defp source_preview_for(module) do
    module
    |> source_for()
    |> line_preview(@max_preview_lines)
  end

  defp resolve_module(nil), do: nil
  defp resolve_module(""), do: nil

  defp resolve_module(module_name) when is_binary(module_name) do
    String.to_existing_atom("Elixir." <> module_name)
  rescue
    ArgumentError -> nil
  end

  defp current_llm_opts(opts) do
    config = Config.load(config_path: Keyword.get(opts, :config_path))

    [
      provider: Config.provider_to_atom(config.provider),
      model: config.model,
      api_key: Config.get_current_api_key(config),
      base_url: Config.get_current_base_url(config)
    ]
  end

  defp load_session(session_key, opts) do
    if Process.whereis(SessionManager) do
      SessionManager.get(session_key, workspace_opts(opts)) ||
        Session.load(session_key, workspace_opts(opts))
    else
      Session.load(session_key, workspace_opts(opts))
    end
  end

  defp load_session_from_path(path) do
    if File.exists?(path) do
      try do
        Session.load_from_path(path)
      rescue
        _ -> nil
      end
    end
  end

  defp runtime_run_summary(path) do
    lines = decode_runtime_run_lines(path)

    started = Enum.find(lines, &(&1["type"] == "run_started")) || %{}
    completed = Enum.find(lines, &(&1["type"] == "run_completed")) || %{}
    selected = Enum.find(lines, &(&1["type"] == "skills_selected")) || %{}

    if started == %{} and completed == %{} and selected == %{} do
      nil
    else
      %{
        run_id:
          started["run_id"] || completed["run_id"] || selected["run_id"] ||
            Path.basename(path, ".jsonl"),
        prompt: truncate_text(started["prompt"], 140),
        inserted_at:
          started["inserted_at"] || completed["inserted_at"] || selected["inserted_at"],
        status: completed["status"] || "completed",
        result: truncate_text(completed["result"], 200),
        packages: selected["packages"] || []
      }
    end
  end

  defp decode_runtime_run_lines(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.with_index(1)
        |> Enum.reduce([], fn {line, line_number}, acc ->
          case Jason.decode(line) do
            {:ok, decoded} when is_map(decoded) ->
              [decoded | acc]

            {:ok, decoded} ->
              Logger.debug(
                "[Admin] Skipping non-map runtime run entry #{path}:#{line_number}: #{inspect(decoded)}"
              )

              acc

            {:error, reason} ->
              Logger.debug(
                "[Admin] Skipping malformed runtime run entry #{path}:#{line_number}: #{inspect(reason)}"
              )

              acc
          end
        end)
        |> Enum.reverse()

      {:error, _} ->
        []
    end
  end

  defp workspace(opts) do
    Keyword.get(opts, :workspace) || Workspace.root(opts)
  end

  defp workspace_opts(opts) do
    [workspace: workspace(opts)]
  end

  defp read_json_array(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, rows} when is_list(rows) -> rows
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp file_preview(path, max_lines \\ 40) do
    path
    |> read_file()
    |> line_preview(max_lines)
  end

  defp line_preview(content, max_lines) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.take(max_lines)
    |> Enum.join("\n")
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _} -> 0
    end
  end

  defp truncate_text(nil, _limit), do: nil
  defp truncate_text("", _limit), do: ""

  defp truncate_text(text, limit) when is_binary(text) do
    if String.length(text) <= limit do
      text
    else
      String.slice(text, 0, limit) <> "..."
    end
  end

  defp preview_summary(content, fallback) do
    content
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        fallback

      text ->
        text
        |> String.replace(~r/\s+/, " ")
        |> truncate_text(140)
    end
  end

  defp to_naive(%DateTime{} = value), do: DateTime.to_naive(value)
  defp to_naive(%NaiveDateTime{} = value), do: value

  defp to_naive(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} ->
        naive

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> DateTime.to_naive(dt)
          _ -> ~N[1970-01-01 00:00:00]
        end
    end
  end

  defp to_naive(_), do: ~N[1970-01-01 00:00:00]

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(1), do: true
  defp truthy(_), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
