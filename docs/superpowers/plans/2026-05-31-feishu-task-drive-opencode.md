# Feishu Task → OpenCode Driver Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** User creates Feishu tasks → nex-agent detects in near-real-time → dispatches to opencode CLI → reports results back to task + notifies user.

**Architecture:** Extend Feishu WebSocket channel with 3 task event handlers (created/updated/comment). Route them via `_from_feishu_task` metadata similar to `_from_cron`. A markdown-only skill guides the LLM through lock acquisition, opencode execution, result reporting, and dequeue.

**Tech Stack:** Elixir (channel extension), Markdown skill, bash/lark-cli tools (existing), file-based lock + dedup + queue.

**Spec:** `docs/superpowers/specs/2026-05-31-feishu-task-drive-opencode-design.md`

---

## File Structure

| File | Role |
|------|------|
| `lib/nex/agent/channel/feishu_task.ex` | New: task event normalization + dedup registry |
| `lib/nex/agent/channel/feishu.ex` | Modify: add task event branch in normalize_event |
| `lib/nex/agent/inbound_worker.ex` | Modify: route `_from_feishu_task` with skill injection |
| `lib/nex/agent/context_builder.ex` | Modify: support forced always-skills override |
| `priv/skills/feishu-task-executor/SKILL.md` | New: execution skill for Agent |

---

### Task 1: Task Event Normalizer + Dedup Registry

**Files:**
- Create: `lib/nex/agent/channel/feishu_task.ex`
- Modify: `lib/nex/agent/channel/feishu.ex:776-799`

- [ ] **Step 1: Create `feishu_task.ex`**

```elixir
defmodule Nex.Agent.Channel.FeishuTask do
  @moduledoc false
  require Logger

  @dedup_ttl_seconds 300
  @dedup_dir "tasks"

  def normalize(%{"header" => %{"event_type" => "task.task.created_v1"}} = payload) do
    task = payload["event"] || %{}
    task_id = task["task_id"]
    operator_id = get_in(payload, ["header", "operator_user_id"])
    creator_id = task["creator_id"] || operator_id

    if is_nil(task_id) or task_id == "" do
      Logger.warning("[FeishuTask] created event missing task_id")
      :ignore
    else
      {:ok,
       %{
         channel: "feishu",
         chat_id: creator_id,
         content: "/run_feishu_task #{task_id}",
         metadata: %{
           _from_feishu_task: true,
           task_id: task_id,
           task_title: task["title"] || "",
           task_description: task["description"] || "",
           task_action: "created",
           creator_id: creator_id,
           operator_user_id: operator_id
         }
       }}
    end
  end

  def normalize(%{"header" => %{"event_type" => "task.task.updated_v1"}} = payload) do
    task = payload["event"] || %{}
    task_id = task["task_id"]
    old_status = get_in(task, ["changes", "status", "old"]) || ""
    new_status = get_in(task, ["changes", "status", "new"]) || ""
    operator_id = get_in(payload, ["header", "operator_user_id"])
    creator_id = task["creator_id"] || operator_id

    if task_id && old_status == "completed" && new_status == "in_progress" &&
         operator_id == creator_id do
      {:ok,
       %{
         channel: "feishu",
         chat_id: creator_id,
         content: "/rerun_feishu_task #{task_id}",
         metadata: %{
           _from_feishu_task: true,
           task_id: task_id,
           task_title: task["title"] || "",
           task_description: task["description"] || "",
           task_action: "rerun",
           creator_id: creator_id,
           operator_user_id: operator_id
         }
       }}
    else
      :ignore
    end
  end

  def normalize(%{"header" => %{"event_type" => "task.task.comment.created_v1"}} = payload) do
    task = payload["event"] || %{}
    task_id = task["task_id"]
    comment = get_in(task, ["comment", "content"]) || ""
    operator_id = get_in(payload, ["header", "operator_user_id"])
    creator_id = task["creator_id"] || operator_id

    if task_id && comment =~ "/rerun" && operator_id == creator_id do
      {:ok,
       %{
         channel: "feishu",
         chat_id: creator_id,
         content: "/rerun_feishu_task #{task_id}",
         metadata: %{
           _from_feishu_task: true,
           task_id: task_id,
           task_title: task["title"] || "",
           task_description: task["description"] || "",
           task_action: "rerun",
           creator_id: creator_id,
           operator_user_id: operator_id
         }
       }}
    else
      :ignore
    end
  end

  def normalize(_payload), do: :not_matched

  def dup?(bot_open_id, operator_id, task_id, action, workspace) do
    cond do
      operator_id == bot_open_id ->
        true

      true ->
        dedup_dup?(task_id, action, workspace)
    end
  end

  def record_dedup(task_id, action, workspace) do
    entries = read_dedup(workspace)
    now = System.system_time(:second)
    expires_at = now + @dedup_ttl_seconds

    pruned =
      Enum.reject(entries, fn %{"expires_at" => exp} -> now >= exp end) ++
        [%{"task_id" => task_id, "action" => action, "expires_at" => expires_at}]

    File.mkdir_p!(Path.join(workspace, @dedup_dir))
    File.write!(dedup_path(workspace), Jason.encode!(pruned))
  end

  defp dedup_dup?(task_id, action, workspace) do
    entries = read_dedup(workspace)
    now = System.system_time(:second)

    Enum.any?(entries, fn %{"task_id" => tid, "action" => act, "expires_at" => exp} ->
      tid == task_id and act == action and now < exp
    end)
  end

  defp read_dedup(workspace) do
    path = dedup_path(workspace)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, entries} when is_list(entries) -> entries
          _ -> []
        end

      _ ->
        []
    end
  end

  defp dedup_path(workspace), do: Path.join([workspace, @dedup_dir, "dedup.json"])
end
```

- [ ] **Step 2: Modify Feishu channel — add task event branch**

In `lib/nex/agent/channel/feishu.ex`, modify `normalize_event/1` (line ~776). Insert a task-event branch BEFORE the existing `normalize_event(payload)` when-clause:

```elixir
  defp normalize_event(%{"header" => %{"event_type" => type}} = payload)
       when type in ~w(task.task.created_v1 task.task.updated_v1 task.task.comment.created_v1) do
    Nex.Agent.Channel.FeishuTask.normalize(payload)
  end
```

Add the new clause between the `url_verification` clause (line ~776) and the existing general `normalize_event(payload) when is_map(payload)` clause (line ~781).

- [ ] **Step 3: Modify `handle_ws_event_payload` — add task dedup**

In `lib/nex/agent/channel/feishu.ex:687-705`, replace the `handle_ws_event_payload` function body:

```elixir
  defp handle_ws_event_payload(payload, state) do
    Logger.info("[Feishu] WS event payload=#{inspect(payload, limit: 500, printable_limit: 500)}")

    case normalize_event(payload) do
      {:ok, %{metadata: %{_from_feishu_task: true}} = inbound} ->
        task_id = inbound.metadata.task_id
        action = inbound.metadata.task_action
        operator_id = inbound.metadata.operator_user_id
        workspace = task_workspace()

        if Nex.Agent.Channel.FeishuTask.dup?(state.bot_open_id, operator_id, task_id, action, workspace) do
          Logger.debug("[Feishu] Task event dedup: task=#{task_id} action=#{action}")
          state
        else
          Nex.Agent.Channel.FeishuTask.record_dedup(task_id, action, workspace)
          Logger.info("[Feishu] Task inbound id=#{task_id} action=#{action}")
          Bus.publish(:inbound, inbound)
          state
        end

      {:ok, inbound} ->
        Logger.info(
          "[Feishu] Inbound sender=#{inbound[:sender_id]} chat=#{inbound[:chat_id]} content=#{inspect(inbound[:content])}"
        )

        process_inbound_message(inbound, state)

      :ignore ->
        Logger.debug("[Feishu] Event ignored keys=#{inspect(Map.keys(payload))}")
        state

      {:challenge, _} ->
        state
    end
  end

  defp task_workspace do
    Application.get_env(:nex_agent, :workspace_path) ||
      Path.expand("~/.nex/agent/workspace")
  end
```

- [ ] **Step 5: Compile and verify**

```
mix compile
```
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add lib/nex/agent/channel/feishu_task.ex lib/nex/agent/channel/feishu.ex
git commit -m "feat: add task event handlers + dedup for Feishu Task driver"
```

---

### Task 2: Skill Routing in InboundWorker + ContextBuilder

**Files:**
- Modify: `lib/nex/agent/inbound_worker.ex:249-270` (add `from_feishu_task` options)
- Modify: `lib/nex/agent/context_builder.ex:225-237` (support `force_skills` override)

- [ ] **Step 1: Add task routing in `dispatch_async`**

In `lib/nex/agent/inbound_worker.ex`, inside `dispatch_async/6` (line ~249), add after `from_subagent`:

```elixir
    from_cron = get_in(payload, [:metadata, "_from_cron"]) == true
    from_subagent = get_in(payload, [:metadata, "_from_subagent"]) == true
    from_feishu_task = get_in(payload, [:metadata, "_from_feishu_task"]) == true
    media = extract_media(payload)

    cron_opts =
      if from_cron,
        do: [
          history_limit: 0,
          tools_filter: :cron,
          skip_consolidation: true,
          max_iterations: 3,
          skip_skills: true
        ],
        else: []

    task_opts =
      if from_feishu_task,
        do: [
          force_skills: ["feishu-task-executor"],
          skip_outbound: true,
          max_iterations: 10
        ],
        else: []
```

Then merge `task_opts` into the opts passed to `agent_prompt_fun`. The current code at line ~288-300 passes:
```elixir
state.agent_prompt_fun.(agent, content,
  [channel: ..., chat_id: ..., ...] |> maybe_put_opt(:media, media) |> Kernel.++(cron_opts))
```

Change `Kernel.++(cron_opts)` to `|> Kernel.++(cron_opts) |> Kernel.++(task_opts)`:

```elixir
            result =
              state.agent_prompt_fun.(
                agent,
                content,
                [
                  channel: channel,
                  chat_id: chat_id,
                  on_progress: nil,
                  workspace: workspace,
                  schedule_memory_refresh: false
                ]
                |> maybe_put_opt(:media, media)
                |> Kernel.++(cron_opts)
                |> Kernel.++(task_opts)
              )
```

- [ ] **Step 2: Suppress outbound for task dispatches**

In `handle_info({:async_result, key, {:ok, result, updated_agent}, payload}, state)` (line ~84), suppress outbound when `from_feishu_task`:

```elixir
    from_cron = get_in(payload, [:metadata, "_from_cron"]) == true
    from_subagent = get_in(payload, [:metadata, "_from_subagent"]) == true
    from_feishu_task = get_in(payload, [:metadata, "_from_feishu_task"]) == true

    # Don't overwrite user agent with cron/task's ephemeral agent
    state =
      if from_cron or from_feishu_task, do: state, else: put_in(state.agents[key], updated_agent)

    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}

    unless result == :message_sent or from_cron or from_feishu_task or suppress_outbound?(result) do
      publish_outbound(payload, result)
    end

    maybe_enqueue_memory_refresh(updated_agent, payload, from_cron, from_subagent)
```

Same pattern for the `{:error, reason, updated_agent}` handler (line ~104) and the `{:error, reason}` handler (line ~123).

- [ ] **Step 3: Support `force_skills` in ContextBuilder**

In `lib/nex/agent/context_builder.ex`, modify `add_always_skills/3`:

```elixir
  defp add_always_skills(parts, workspace, opts) do
    force_skills = Keyword.get(opts, :force_skills, [])

    if force_skills != [] do
      force_content =
        force_skills
        |> Enum.map(fn name -> Skills.read_skill_instructions(name, workspace: workspace) end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      if String.trim(force_content) == "" do
        parts
      else
        parts ++ [force_content]
      end
    else
      if Keyword.get(opts, :skip_skills, false) do
        parts
      else
        content = Skills.always_instructions(workspace: workspace)

        if String.trim(content) == "" do
          parts
        else
          parts ++ [content]
        end
      end
    end
  end
```

Also add `read_skill_instructions/2` to the Skills module (or use the existing pattern for loading a skill by name). Check if `Skills.read/2` exists:

- [ ] **Step 3a: Add `Skills.read_skill_instructions/2` if needed**

```elixir
  def read_skill_instructions(name, opts \\ []) do
    workspace_opts = workspace_opts(opts)
    skill_path = Path.join([Skills.skills_dir(workspace_opts), name, "SKILL.md"])

    case File.read(skill_path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end
```

Or read from `priv/skills/`:

```elixir
  def read_skill_instructions(name, _opts) do
    priv_path = Path.join(:code.priv_dir(:nex_agent), "skills/#{name}/SKILL.md")

    case File.read(priv_path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end
```

- [ ] **Step 4: Pass `force_skills` through Runner**

In `lib/nex/agent/runner.ex:71-76`, add `force_skills` to the ContextBuilder opts:

```elixir
    messages =
      ContextBuilder.build_messages(history, prompt, channel, chat_id, media,
        skip_skills: Keyword.get(opts, :skip_skills, false),
        force_skills: Keyword.get(opts, :force_skills, []),
        workspace: workspace,
        runtime_system_messages: runtime_system_messages,
        cwd: Keyword.get(opts, :cwd)
      )
```

- [ ] **Step 5: Compile and verify**

```
mix compile
```
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add lib/nex/agent/inbound_worker.ex lib/nex/agent/context_builder.ex lib/nex/agent/runner.ex
git commit -m "feat: add feishu task routing with forced skill injection"
```

---

### Task 3: Execution Skill (Markdown)

**Files:**
- Create: `priv/skills/feishu-task-executor/SKILL.md`

- [ ] **Step 1: Create the skill file**

```markdown
---
name: feishu-task-executor
description: Execute a Feishu task by dispatching it to opencode CLI for coding work. Reports results back to the task.
user-invocable: false
always: false
---

# Feishu Task Executor

You received a feishu task event. Your job: dispatch it to opencode, report results.

## Step 1: Parse the task

Extract from the metadata:
- task_id
- task_title
- task_description
- task_action (created or rerun)

## Step 2: Resolve the target repo

Try in order:
1. Read the task's custom field "仓库" via `bash("lark-cli task get <task_id>")` and extract the `custom_fields` values.
2. Look for `@repo:` annotation in task_description.
3. Look up `workspace/tasks/repos.json` for alias matching.
4. If still unresolved, use `message` tool to ask the user "不能确定任务 `<title>` 对应的仓库。请回复仓库路径或别名。" and STOP. When user replies, save the alias:
```
echo '"<alias>": "<path>"' >> workspace/tasks/repos.json
```
Then re-trigger the task by updating status from completed back to in_progress.

## Step 3: Acquire repo lock

Use atomic mkdir lock:
```
REPO_HASH=$(echo -n "<repo_path>" | shasum -a 256 | cut -d' ' -f1)
LOCK_DIR="workspace/tasks/locks/$REPO_HASH"
mkdir "$LOCK_DIR" && echo '{"task_id":"...","started_at":"..."}' > "$LOCK_DIR/meta.json"
```

If mkdir fails (lock held):
1. Append to `workspace/tasks/queues/pending.jsonl`: `{"task_id":"...", "repo":"...", "enqueued_at":"..."}`
2. Update task: `lark-cli task update <task_id> --status in_progress`
3. Add comment: "排队中，前面的任务完成后自动执行。"
4. STOP.

## Step 4: Execute opencode

Update task status: `lark-cli task update <task_id> --status in_progress`

Run opencode:
```
cd <repo_path> && opencode -m "<task_title>: <task_description>" 2>&1
```

Capture exit code and output. Timeout: 600 seconds.

## Step 5: Report results

Read opencode output. If exit code 0 → completed, else keep in_progress.

Add comment with output summary (first 500 chars):
```
lark-cli task comment <task_id> --content "执行结果: <summary>"
```

Update task status if successful:
```
lark-cli task update <task_id> --status completed
```

Notify the user via `message` tool with task link and result summary.

## Step 6: Release lock + dequeue

```
rm -rf "workspace/tasks/locks/$REPO_HASH"
```

Check `workspace/tasks/queues/pending.jsonl`. If entries exist for this repo:
1. Dequeue the first entry
2. Store its task_id in metadata and restart from Step 2
```

- [ ] **Step 2: Verify file location**

```bash
ls priv/skills/feishu-task-executor/SKILL.md
```

- [ ] **Step 3: Verify skill loads**

```bash
mix compile
```
Skill should be installable by the system. Since it's in `priv/skills/`, it gets bundled.

- [ ] **Step 4: Commit**

```bash
git add priv/skills/feishu-task-executor/SKILL.md
git commit -m "feat: add feishu-task-executor skill"
```

---

### Task 4: Integration Test & Polish

**Files:**
- Modify: `lib/nex/agent/skills.ex` (if needed for `read_skill_instructions`)
- Test: manual end-to-end test

- [ ] **Step 1: Verify skill loading in ContextBuilder**

Run:
```
mix compile
```
Expected: no warnings about missing modules.

- [ ] **Step 2: Verify InboundWorker routing compiles**

```
mix compile --warnings-as-errors
```
Expected: no errors.

- [ ] **Step 3: Run existing tests**

```
mix test
```
Expected: no new failures beyond pre-existing ones.

- [ ] **Step 4: Extend `task_list` to show repos**

In `lib/nex/agent/tool/task.ex` (the task tool), add a `repos` section to the output when available. Read `workspace/tasks/repos.json` and include aliases in the task list response.

Alternative: add a simple `read` of `tasks/repos.json` as part of the tool's `list` action.

- [ ] **Step 4a: Create `tasks/repos.json` template**

```
mkdir -p ~/.nex/agent/workspace/tasks && \
echo '{"nex-agent": "/Users/fenix/github/nex-agent"}' > ~/.nex/agent/workspace/tasks/repos.json
```

In the workspace tasks directory, create a template alias file. This is a runtime file, not version-controlled. Document it:
```
echo '{"nex-agent": "/Users/fenix/github/nex-agent"}' > ~/.nex/agent/workspace/tasks/repos.json
```

- [ ] **Step 5: Commit final polish**

```bash
git add lib/nex/agent/skills.ex
git commit -m "chore: add Skills.read_skill_instructions for force_skills support"
```
