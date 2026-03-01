defmodule Nex.Agent.Runner do
  alias Nex.Agent.{
    Session,
    Entry,
    Tool.Read,
    Tool.Write,
    Tool.Edit,
    Tool.Bash,
    Skills,
    Memory,
    Evolution,
    Evaluation,
    Evolution.Workflow
  }

  @default_max_iterations 10

  @doc """
  Run an agent session with the given prompt.

  Options:
    - :max_iterations - Maximum number of iterations (default: 10)
    - :provider - LLM provider (:anthropic, :openai, :ollama)
    - :model - Model name
    - :api_key - API key for the provider
    - :base_url - Custom base URL for the provider
    - :cwd - Current working directory
    - :llm_client - For testing: a function that mocks LLM responses
  """
  def run(session, prompt, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    llm_client = Keyword.get(opts, :llm_client)

    system_prompt = Nex.Agent.SystemPrompt.build(cwd: cwd)

    messages = [
      %{"role" => "system", "content" => system_prompt}
      | Session.current_messages(session)
    ]

    user_message = %{"role" => "user", "content" => prompt}
    session = add_message(session, user_message)
    messages = messages ++ [user_message]

    run_loop(session, messages, 0, max_iterations,
      provider: provider,
      model: model,
      api_key: api_key,
      base_url: base_url,
      cwd: cwd,
      llm_client: llm_client
    )
  end

  defp execute_tool("evolve_proposals", _args, _opts) do
    proposals = Workflow.list_pending()

    if proposals == [] do
      {:ok, %{result: "No pending evolution proposals"}}
    else
      formatted =
        Enum.map_join(proposals, "\n", fn p ->
          "- #{p.id} module=#{p.module} risk=#{p.policy.risk_level} created_at=#{p.created_at}"
        end)

      {:ok, %{result: "Pending proposals:\n#{formatted}"}}
    end
  end

  defp execute_tool("evolve_approve", args, _opts) do
    proposal_id = args["proposal_id"]
    eval_window_days = args["eval_window_days"] || 3

    if is_nil(proposal_id) do
      {:error, "proposal_id is required"}
    else
      case Workflow.approve_and_apply(proposal_id) do
        {:ok, %{module: module, version: version}} ->
          baseline = Evaluation.evaluate_recent(window_days: eval_window_days)

          eval =
            Evaluation.evaluate_candidate(module,
              baseline: baseline,
              candidate: baseline,
              min_success_rate: 0.50,
              max_score_regression: 5
            )

          if eval.passed do
            {:ok,
             %{
               result:
                 "Approved and applied proposal #{proposal_id}. Version=#{version.id}. Eval=#{eval.summary}"
             }}
          else
            rollback_result = Evolution.rollback(module)

            {:error,
             "Approved proposal applied but failed evaluation gate: #{Enum.join(eval.reasons, "; ")}. Auto-rollback: #{inspect(rollback_result)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_tool("evolve_reject", args, _opts) do
    proposal_id = args["proposal_id"]

    if is_nil(proposal_id) do
      {:error, "proposal_id is required"}
    else
      case Workflow.reject(proposal_id) do
        :ok -> {:ok, %{result: "Rejected proposal #{proposal_id}"}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp run_loop(session, messages, iteration, max_iterations, opts) do
    if iteration >= max_iterations do
      {:error, :max_iterations_exceeded, session}
    else
      case call_llm(messages, opts) do
        {:ok, response} ->
          content = response.content
          tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

          if tool_calls && tool_calls != [] do
            session =
              add_message(session, %{
                "role" => "assistant",
                "content" => content,
                "tool_calls" => tool_calls
              })

            messages =
              messages ++
                [%{"role" => "assistant", "content" => content, "tool_calls" => tool_calls}]

            {new_messages, _results} = execute_tools(session, messages, tool_calls, opts)
            run_loop(session, new_messages, iteration + 1, max_iterations, opts)
          else
            session = add_message(session, %{"role" => "assistant", "content" => content})
            {:ok, content, session}
          end

        {:error, reason} ->
          {:error, reason, session}
      end
    end
  end

  defp call_llm(messages, opts) do
    # Check if a test client is provided
    if opts[:llm_client] do
      opts[:llm_client].(messages, opts ++ [tools: all_tools()])
    else
      call_llm_real(messages, opts)
    end
  end

  defp all_tools do
    # Built-in tools
    tools = [
      %{
        "name" => "read",
        "description" => "Read a file from the filesystem",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Path to the file to read"}
          },
          "required" => ["path"]
        }
      },
      %{
        "name" => "write",
        "description" => "Write content to a file",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Path to write to"},
            "content" => %{"type" => "string", "description" => "Content to write"}
          },
          "required" => ["path", "content"]
        }
      },
      %{
        "name" => "edit",
        "description" => "Edit a file by replacing specific text",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Path to the file"},
            "search" => %{"type" => "string", "description" => "Text to find"},
            "replace" => %{"type" => "string", "description" => "Text to replace with"}
          },
          "required" => ["path", "search", "replace"]
        }
      },
      %{
        "name" => "bash",
        "description" => "Execute a bash command",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{"type" => "string", "description" => "Command to execute"}
          },
          "required" => ["command"]
        }
      },
      %{
        "name" => "web_search",
        "description" => "Search the web using Brave Search API",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query"},
            "count" => %{
              "type" => "integer",
              "description" => "Number of results (1-10)",
              "minimum" => 1,
              "maximum" => 10
            }
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "web_fetch",
        "description" => "Fetch and extract content from a URL",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string", "description" => "URL to fetch"}
          },
          "required" => ["url"]
        }
      }
    ]

    # Add Skills
    skills = Skills.for_llm()

    skill_tools =
      Enum.map(skills, fn skill ->
        skill_name = Map.get(skill, "name") || Map.get(skill, :name)
        skill_description = Map.get(skill, "description") || Map.get(skill, :description)

        %{
          "name" => skill_name,
          "description" => skill_description,
          "input_schema" => %{
            "type" => "object",
            "properties" => %{
              "arguments" => %{
                "type" => "string",
                "description" =>
                  Map.get(skill, "argument_hint") || Map.get(skill, :argument_hint) ||
                    "Arguments for the skill"
              }
            }
          }
        }
      end)

    # Add skills_list tool
    skills_list_tool = %{
      "name" => "skills_list",
      "description" => "List all available skills",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    }

    # Add skill_create tool
    skill_create_tool = %{
      "name" => "skill_create",
      "description" => "Create a new skill for automating repetitive tasks",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Skill name (snake_case)"},
          "description" => %{"type" => "string", "description" => "What this skill does"},
          "type" => %{
            "type" => "string",
            "description" => "Skill type: elixir, script, mcp, or markdown"
          },
          "code" => %{"type" => "string", "description" => "The actual code/script/content"},
          "parameters" => %{"type" => "object", "description" => "JSON Schema for parameters"}
        },
        "required" => ["name", "description"]
      }
    }

    # Add skill_execute tool
    skill_execute_tool = %{
      "name" => "skill_execute",
      "description" => "Execute a skill with arguments",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Skill name to execute"},
          "arguments" => %{"type" => "object", "description" => "Arguments for the skill"}
        },
        "required" => ["name", "arguments"]
      }
    }

    # Add skill_delete tool
    skill_delete_tool = %{
      "name" => "skill_delete",
      "description" => "Delete a skill by name",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Skill name to delete"}
        },
        "required" => ["name"]
      }
    }

    # Add Memory search
    memory_tools = [
      %{
        "name" => "memory_search",
        "description" => "Search agent memory for past experiences",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query"}
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "memory_append",
        "description" => "Save important information to memory",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "task" => %{"type" => "string", "description" => "Task description"},
            "result" => %{"type" => "string", "description" => "Result (SUCCESS/FAILURE)"}
          },
          "required" => ["task", "result"]
        }
      }
    ]

    tools ++
      skill_tools ++
      [skills_list_tool, skill_create_tool, skill_execute_tool, skill_delete_tool] ++
      memory_tools ++ evolution_tools() ++ mcp_tools()
  end

  defp mcp_tools do
    [
      %{
        "name" => "mcp_discover",
        "description" => "Discover available MCP servers from PATH",
        "input_schema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "mcp_start",
        "description" => "Start an MCP server",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Server name"},
            "command" => %{"type" => "string", "description" => "Command to run"},
            "args" => %{"type" => "array", "description" => "Arguments"}
          },
          "required" => ["name", "command"]
        }
      },
      %{
        "name" => "mcp_stop",
        "description" => "Stop an MCP server",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "server_id" => %{"type" => "string", "description" => "Server ID to stop"}
          },
          "required" => ["server_id"]
        }
      },
      %{
        "name" => "mcp_list",
        "description" => "List running MCP servers",
        "input_schema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "mcp_call",
        "description" => "Call a tool on an MCP server",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "server_id" => %{"type" => "string", "description" => "Server ID"},
            "tool" => %{"type" => "string", "description" => "Tool name"},
            "arguments" => %{"type" => "object", "description" => "Tool arguments"}
          },
          "required" => ["server_id", "tool"]
        }
      }
    ]
  end

  defp evolution_tools do
    [
      %{
        "name" => "evolve_code",
        "description" => "Modify and reload agent code with policy checks and evaluation gate",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "module" => %{
              "type" => "string",
              "description" => "Module name to modify (e.g., Nex.Agent.Runner)"
            },
            "code" => %{"type" => "string", "description" => "New Elixir code for the module"},
            "auto_approve" => %{
              "type" => "boolean",
              "description" => "Force direct apply even for risky modules"
            },
            "eval_window_days" => %{
              "type" => "integer",
              "description" => "How many days of memory to use for evaluation (default: 3)"
            }
          },
          "required" => ["module", "code"]
        }
      },
      %{
        "name" => "evolve_rollback",
        "description" => "Rollback to previous version of a module",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "module" => %{"type" => "string", "description" => "Module name to rollback"}
          },
          "required" => ["module"]
        }
      },
      %{
        "name" => "evolve_versions",
        "description" => "List all versions of a module",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "module" => %{"type" => "string", "description" => "Module name"}
          },
          "required" => ["module"]
        }
      },
      %{
        "name" => "evolve_proposals",
        "description" => "List pending evolution proposals",
        "input_schema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "evolve_approve",
        "description" => "Approve and apply a pending evolution proposal",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "proposal_id" => %{"type" => "string", "description" => "Proposal ID"},
            "eval_window_days" => %{
              "type" => "integer",
              "description" => "How many days of memory to use for evaluation (default: 3)"
            }
          },
          "required" => ["proposal_id"]
        }
      },
      %{
        "name" => "evolve_reject",
        "description" => "Reject a pending evolution proposal",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "proposal_id" => %{"type" => "string", "description" => "Proposal ID"}
          },
          "required" => ["proposal_id"]
        }
      },
      %{
        "name" => "reflect",
        "description" => "Analyze recent execution results and generate insights",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "auto_apply" => %{
              "type" => "boolean",
              "description" => "Automatically apply suggestions"
            }
          }
        }
      }
    ]
  end

  defp call_llm_real(messages, opts) do
    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model)
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)

    provider_opts =
      [
        model: model,
        api_key: api_key,
        base_url: base_url
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    case provider do
      :anthropic ->
        Nex.Agent.LLM.Anthropic.chat(messages, provider_opts)

      :openai ->
        Nex.Agent.LLM.OpenAI.chat(messages, provider_opts)

      :openrouter ->
        Nex.Agent.LLM.OpenRouter.chat(messages, provider_opts)

      :ollama ->
        Nex.Agent.LLM.Ollama.chat(messages, provider_opts)

      _ ->
        {:error, "Unknown provider: #{provider}"}
    end
  end

  defp execute_tools(_session, messages, tool_calls, opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    results =
      Enum.map(tool_calls, fn tc ->
        tool_name = get_in(tc, ["function", "name"]) || get_in(tc, [:function, :name])
        raw_args = get_in(tc, ["function", "arguments"]) || get_in(tc, [:function, :arguments])
        args = normalize_tool_arguments(raw_args)

        result =
          case args do
            {:error, reason} -> {:error, reason}
            parsed_args -> execute_tool(tool_name, parsed_args, cwd: cwd)
          end

        tool_result = %{
          "role" => "tool",
          "tool_call_id" => tc["id"],
          "content" => format_result(result)
        }

        {tc["id"], tool_result}
      end)

    tool_messages = Enum.map(results, fn {_, msg} -> msg end)
    {messages ++ tool_messages, results}
  end

  defp execute_tool("read", args, opts) do
    Read.execute(args, %{cwd: opts[:cwd]})
  end

  defp execute_tool("write", args, opts) do
    Write.execute(args, %{cwd: opts[:cwd]})
  end

  defp execute_tool("edit", args, opts) do
    Edit.execute(args, %{cwd: opts[:cwd]})
  end

  defp execute_tool("bash", args, opts) do
    Bash.execute(args, %{cwd: opts[:cwd]})
  end

  defp execute_tool("web_search", args, _opts) do
    Nex.Agent.Tool.WebSearch.execute(args, %{})
  end

  defp execute_tool("web_fetch", args, _opts) do
    Nex.Agent.Tool.WebFetch.execute(args, %{})
  end

  defp execute_tool("memory_search", args, _opts) do
    query = args["query"] || ""
    results = Memory.search(query)

    if results == [] do
      {:ok, %{result: "No memories found for: #{query}"}}
    else
      formatted =
        Enum.map(results, fn r ->
          "#{r.entry.task} - #{r.entry.result}\n#{r.entry.body}\n---\n"
        end)
        |> Enum.join()

      {:ok, %{result: formatted}}
    end
  end

  defp execute_tool("memory_append", args, _opts) do
    task = args["task"] || ""
    result = args["result"] || "UNKNOWN"
    metadata = Map.get(args, "metadata", %{})

    case Memory.append(task, result, metadata) do
      :ok -> {:ok, %{result: "Memory saved: #{task}"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool("skill_" <> skill_name, args, _opts) do
    # Skills are called as skill_<name>
    arguments = args["arguments"] || ""

    case Skills.execute(skill_name, arguments, invoked_by: :model) do
      {:ok, content} -> {:ok, %{result: content}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool("skills_list", _args, _opts) do
    skills = Skills.list()

    formatted =
      Enum.map_join(skills, "\n", fn s ->
        type = s.type || "markdown"
        "- #{s.name} (#{type}): #{s.description}"
      end)

    {:ok, %{result: "Available skills:\n#{formatted}"}}
  end

  defp execute_tool("skill_create", args, _opts) do
    name = args["name"]
    description = args["description"]
    type = args["type"] || "markdown"
    code = args["code"] || ""
    parameters = args["parameters"] || %{}

    if is_nil(name) do
      {:error, "Skill name is required"}
    else
      case Skills.create(%{
             name: name,
             description: description,
             type: type,
             code: code,
             parameters: parameters
           }) do
        {:ok, skill} ->
          Memory.append(
            "Created skill: #{name}",
            "SUCCESS",
            %{type: :skill_create, skill_type: type}
          )

          {:ok, %{result: "Successfully created skill '#{name}' (type: #{type})"}}

        {:error, reason} ->
          Memory.append(
            "Failed to create skill: #{name}",
            "FAILURE",
            %{type: :skill_create, error: reason}
          )

          {:error, reason}
      end
    end
  end

  defp execute_tool("skill_execute", args, _opts) do
    name = args["name"]
    arguments = args["arguments"] || %{}

    if is_nil(name) do
      {:error, "Skill name is required"}
    else
      case Skills.execute(name, arguments, invoked_by: :user) do
        {:ok, result} ->
          formatted =
            if is_map(result) do
              Map.get(result, :result) || Map.get(result, :content) || Jason.encode!(result)
            else
              result
            end

          Memory.append(
            "Executed skill: #{name}",
            "SUCCESS",
            %{type: :skill_execute, args: arguments}
          )

          {:ok, %{result: formatted}}

        {:error, reason} ->
          Memory.append(
            "Failed to execute skill: #{name}",
            "FAILURE",
            %{type: :skill_execute, error: reason}
          )

          {:error, reason}
      end
    end
  end

  defp execute_tool("skill_delete", args, _opts) do
    name = args["name"]

    if is_nil(name) do
      {:error, "Skill name is required"}
    else
      case Skills.delete(name) do
        :ok ->
          Memory.append(
            "Deleted skill: #{name}",
            "SUCCESS",
            %{type: :skill_delete}
          )

          {:ok, %{result: "Successfully deleted skill '#{name}'"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Evolution tools
  defp execute_tool("evolve_code", args, _opts) do
    module_str = args["module"]
    code = args["code"]
    auto_approve = args["auto_approve"] == true
    eval_window_days = args["eval_window_days"] || 3

    if is_nil(module_str) || is_nil(code) do
      {:error, "Both module and code are required"}
    else
      module = String.to_atom(module_str)

      case Workflow.evolve(module, code,
             auto_approve: auto_approve,
             metadata: %{source: :tool, requested_module: module_str}
           ) do
        {:ok, %{status: :pending_approval} = pending} ->
          {:ok,
           %{
             result:
               "Evolution proposal queued (#{pending.proposal_id}) for #{module_str}. Approval required.",
             proposal_id: pending.proposal_id
           }}

        {:ok, %{status: :applied, version: version, policy: policy}} ->
          baseline = Evaluation.evaluate_recent(window_days: eval_window_days)

          eval =
            Evaluation.evaluate_candidate(module,
              baseline: baseline,
              candidate: baseline,
              min_success_rate: 0.50,
              max_score_regression: 5
            )

          if eval.passed do
            Memory.append(
              "Evolved: #{module_str}",
              "SUCCESS",
              %{type: :evolution, version: version.id, risk: policy.risk_level, evaluation: eval.summary}
            )

            {:ok,
             %{
               result: "Successfully evolved #{module_str} to version #{version.id}",
               version: version.id,
               evaluation: eval.summary
             }}
          else
            rollback_result = Evolution.rollback(module)

            Memory.append(
              "Failed post-evaluation evolve: #{module_str}",
              "FAILURE",
              %{
                type: :evolution,
                version: version.id,
                evaluation: eval.summary,
                rollback: inspect(rollback_result)
              }
            )

            {:error,
             "Evolution applied but failed evaluation gate: #{Enum.join(eval.reasons, "; ")}. Auto-rollback: #{inspect(rollback_result)}"}
          end

        {:error, reason} ->
          Memory.append("Failed to evolve: #{module_str}", "FAILURE", %{type: :evolution, error: reason})
          {:error, reason}
      end
    end
  end

  defp execute_tool("evolve_rollback", args, _opts) do
    module_str = args["module"]

    if is_nil(module_str) do
      {:error, "module is required"}
    else
      module = String.to_atom(module_str)

      case Evolution.rollback(module) do
        :ok ->
          Memory.append(
            "Rolled back: #{module_str}",
            "SUCCESS",
            %{type: :rollback}
          )

          {:ok, %{result: "Successfully rolled back #{module_str}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_tool("evolve_versions", args, _opts) do
    module_str = args["module"]

    if is_nil(module_str) do
      {:error, "module is required"}
    else
      module = String.to_atom(module_str)
      versions = Evolution.list_versions(module)

      if versions == [] do
        {:ok, %{result: "No versions found for #{module_str}"}}
      else
        formatted =
          Enum.map_join(versions, "\n", fn v ->
            "#{v.id} - #{v.timestamp}"
          end)

        {:ok, %{result: "Versions of #{module_str}:\n#{formatted}"}}
      end
    end
  end

  # Reflection tools
  defp execute_tool("reflect", args, _opts) do
    # This would need to track execution results - for now just show recent memories
    _auto_apply = args["auto_apply"] == true

    # Get recent memories for reflection context
    recent = Memory.search("", limit: 20)

    formatted =
      Enum.map_join(recent, "\n\n", fn r ->
        "#{r.entry.task} - #{r.entry.result}\n#{r.entry.body}"
      end)

    {:ok,
     %{
       result: "Recent experiences:\n#{formatted}\n\nUse memory_search to find specific patterns."
     }}
  end

  # MCP tools
  defp execute_tool("mcp_discover", _args, _opts) do
    servers = Nex.Agent.MCP.Discovery.scan()

    if servers == [] do
      {:ok, %{result: "No MCP servers found in PATH"}}
    else
      formatted =
        Enum.map_join(servers, "\n", fn s ->
          "- #{s.name}: #{s.command}"
        end)

      {:ok, %{result: "Available MCP servers:\n#{formatted}"}}
    end
  end

  defp execute_tool("mcp_start", args, _opts) do
    name = args["name"]
    command = args["command"]
    args_list = args["args"] || []

    if is_nil(name) || is_nil(command) do
      {:error, "name and command are required"}
    else
      case Nex.Agent.MCP.ServerManager.start(name, command: command, args: args_list) do
        {:ok, server_id} ->
          {:ok, %{result: "Started MCP server #{name} with ID: #{server_id}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_tool("mcp_stop", args, _opts) do
    server_id = args["server_id"]

    if is_nil(server_id) do
      {:error, "server_id is required"}
    else
      case Nex.Agent.MCP.ServerManager.stop(server_id) do
        :ok ->
          {:ok, %{result: "Stopped MCP server #{server_id}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_tool("mcp_list", _args, _opts) do
    servers = Nex.Agent.MCP.ServerManager.list()

    if servers == [] do
      {:ok, %{result: "No MCP servers running"}}
    else
      formatted =
        Enum.map_join(servers, "\n", fn s ->
          "- #{s.id} (#{s.name}): #{s.config[:command]}"
        end)

      {:ok, %{result: "Running MCP servers:\n#{formatted}"}}
    end
  end

  defp execute_tool("mcp_call", args, _opts) do
    server_id = args["server_id"]
    tool = args["tool"]
    tool_args = args["arguments"] || %{}

    if is_nil(server_id) || is_nil(tool) do
      {:error, "server_id and tool are required"}
    else
      case Nex.Agent.MCP.ServerManager.call_tool(server_id, tool, tool_args) do
        {:ok, result} ->
          {:ok, %{result: Jason.encode!(result)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_tool(name, _args, _opts) do
    {:error, "Unknown tool: #{name}"}
  end

  defp normalize_tool_arguments(args) when is_map(args), do: args

  defp normalize_tool_arguments(args) when is_binary(args) do
    trimmed = String.trim(args)

    cond do
      trimmed == "" ->
        %{}

      true ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) -> decoded
          {:ok, _decoded} -> {:error, "Tool arguments must decode to an object"}
          {:error, reason} -> {:error, "Invalid tool arguments JSON: #{inspect(reason)}"}
        end
    end
  end

  defp normalize_tool_arguments(_), do: {:error, "Tool arguments must be a map or JSON object string"}

  @tool_result_max_chars 500

  defp format_result({:ok, result}) when is_map(result) do
    result
    |> Map.values()
    |> Enum.join("\n")
    |> truncate_result(@tool_result_max_chars)
  end

  defp format_result({:error, error}) do
    "Error: #{error}"
  end

  defp format_result(result) when is_binary(result) do
    truncate_result(result, @tool_result_max_chars)
  end

  defp truncate_result(result, max_chars) do
    if String.length(result) > max_chars do
      String.slice(result, 0, max_chars) <> "\n\n... [truncated]"
    else
      result
    end
  end

  defp add_message(session, message) do
    entry = Entry.new_message(session.current_entry_id, message)
    Session.add_entry(session, entry)
  end
end
