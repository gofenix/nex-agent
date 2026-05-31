# Feishu Task → OpenCode Driver

## Goal

User creates a Feishu task. NexAgent detects it in near-real-time, dispatches it
to OpenCode for execution, then reports results back to the task and notifies
the user. The Agent itself acts only as a dispatcher/scheduler — it does not
use its own LLM to solve the task.

---

## Architecture

```
Feishu Task System
  │
  ├─ task.task.created_v1         → first run
  ├─ task.task.updated_v1         → re-run (completed→in_progress)
  └─ task.task.comment.created_v1 → re-run (comment contains /rerun)
  │
  │  Feishu WebSocket (existing, extended)
  ▼
Channel.Feishu  (3 new event handlers)
  │  dedup: skip operator_user == bot itself
  │  dedup: skip same task_id within 5 minutes
  │  normalize: task event → unified inbound message
  ▼
InboundWorker → Runner  (existing, unchanged)
  │  Routing: metadata._from_feishu_task == true →
  │    Runner adds "feishu-task-executor" to always-skills list
  │    (same mechanism as other inbound channels, see Runner.prepare_always_skills)
  ▼
feishu-task-executor skill  (new Markdown-only skill)
  │  step 1: resolve repo from custom field / @repo: / alias table
  │  step 2: acquire file lock, queue if busy
  │  step 3: bash(opencode ...) — actual coding work
  │  step 4: lark-cli update task status + comment
  │  step 5: message tool notify user
  │  step 6: release lock, dequeue next
```

---

## Components

### 1. Task Event Handlers (Channel.Feishu)

Extend `lib/nex/agent/channel/feishu.ex` to handle three new Feishu WebSocket
event types:

| Event Type | Handler | Produces |
|-----------|---------|----------|
| `task.task.created_v1` | `handle_task_created/1` | inbound with `task_action: :created` |
| `task.task.updated_v1` | `handle_task_updated/1` | inbound with `task_action: :rerun` (only if status changed completed→in_progress AND operator is the task creator, not the bot) |
| `task.task.comment.created_v1` | `handle_task_comment_created/1` | inbound with `task_action: :rerun` (only if comment text contains `/rerun` AND commenter is task creator) |

Each handler normalizes the Feishu event into the existing inbound message format:

```elixir
%{
  channel: "feishu",
  chat_id: operator_user_id,
  content: "/run_feishu_task #{task_id}",
  metadata: %{
    _from_feishu_task: true,
    task_id: "task_uuid",
    task_title: "...",
    task_description: "...",
    task_action: :created | :rerun
  }
}
```

**Dedup logic** (applied before publishing):
- Skip any event where `header.operator_user_id` matches the bot's own open_id.
  Bot identity is determined on channel startup via Feishu `/authen/tenant_access_token`
  response, cached in channel state as `bot_open_id`.
- Track recently dispatched `task_id` + `task_action` pairs in a file-backed
  dedup registry at `tasks/dedup.json`. Each entry: `{task_id, action, expires_at}`.
  Entries older than `expires_at` (now + 5 minutes) are pruned on write.
  This survives process restarts — a replayed event within the TTL window is
  still dropped. If the registry file is corrupt or missing, start with an
  empty cache (acceptable trade-off; at worst a task runs twice).

### 2. Repo Resolution

The skill resolves the target repository in priority order:

1. **Feishu custom field `仓库`** — if the task has this field populated with a
   directory path or registered alias, use it directly.
2. **Task description `@repo:` annotation** — parse `@repo: /path` or `@repo:
   alias-name` from the task description body.
3. **Alias table** — `workspace/tasks/repos.json`:
   ```json
   {"nex-agent": "/Users/fenix/github/nex-agent", ...}
   ```
4. **Ask the user** — if all resolution steps fail, the Agent sends a message
   to the user asking which repo and records the answer as a new alias.

### 3. File Lock & Queue

Per-repo concurrency control to prevent two tasks from modifying the same
project simultaneously.

**Lock directory**: `workspace/tasks/locks/<sha256(repo_path).hex>/` — contains
`meta.json`: `{"task_id": "...", "started_at": "2026-05-31T10:00:00Z"}`

**Queue file**: `workspace/tasks/queues/pending.jsonl`
```jsonl
{"task_id": "...", "repo": "/path", "enqueued_at": "..."}
```

**Flow**:
- Skill attempts `mkdir tasks/locks/<hash>` (atomic — `mkdir` fails if
  directory already exists, eliminating TOCTOU races).
- If `mkdir` succeeds → lock acquired, write `task_id` and `started_at` into
  `tasks/locks/<hash>/meta.json`, proceed.
- If `mkdir` fails (EEXIST) → lock held. Append to `pending.jsonl`, update
  task status to `in_progress` with comment "排队中，前面的任务完成后自动执行".
- After execution completes (success or failure) → remove lock directory
  (`rmdir tasks/locks/<hash>`), read `pending.jsonl`. If entries exist for
  this repo, dequeue the first one and re-trigger the skill.

### 4. feishu-task-executor Skill

A Markdown-only skill at
`workspace/skills/feishu-task-executor/SKILL.md`. It guides the LLM through a
fixed sequence:

```
1. PARSE CONTEXT
   Read task_id, task_title, task_description, task_action from metadata.
   Resolve the target repo using: custom field > @repo: > alias table > ask.

 2. ACQUIRE LOCK
    bash("mkdir tasks/locks/<hash> && echo '{\"task_id\":\"...\",...}' > tasks/locks/<hash>/meta.json")
    If mkdir fails (already locked) → write to tasks/queues/pending.jsonl,
    set task status to in_progress with "排队中，前面的任务完成后自动执行"
    comment, exit.

 3. EXECUTE OPENCODE
    If task was queued (status already in_progress from queue step), skip the
    status update. Otherwise mark task as in_progress.
    bash("cd <repo> && opencode -m '<title>: <description>'", timeout: 600)

4. REPORT RESULTS
   - success: lark-cli task update <id> --status completed
   - failure: keep status in_progress
   - append comment with output summary (first 500 chars)
   - message tool notify user with task link

 5. RELEASE LOCK + DEQUEUE
    bash("rm -rf tasks/locks/<hash>")
    Check tasks/queues/pending.jsonl. If entries exist for this repo,
    dequeue the first and restart from step 2.
```

### 5. Repo Alias Management

- `task_list` tool extended to also show available repos from `repos.json`.
- Agent can add aliases via `bash`: `echo '...' >> tasks/repos.json`.
- When the Agent asks the user "which repo?" and user replies, Agent writes
  the answer as a new alias automatically.

---

## Files Changed

| File | Change |
|------|--------|
| `lib/nex/agent/channel/feishu.ex` | Add 3 task event handlers, dedup logic |
| `workspace/skills/feishu-task-executor/SKILL.md` | New markdown skill |
| `workspace/tasks/repos.json` | New alias registry (runtime, user-managed) |
| `workspace/tasks/locks/` | New lock directory (runtime) |
| `workspace/tasks/queues/pending.jsonl` | New queue file (runtime) |

No new Elixir modules beyond the Feishu channel extension. All execution logic
is in the skill + existing tools (bash, message, lark-cli).

## Prerequisites

- `opencode` CLI must be on `PATH`. Non-interactive mode used via `-m` flag.
- `lark-cli` must be installed and authenticated for task operations
  (`task get`, `task update`, `task comment`).

---

## Error Handling

| Failure | Behavior |
|---------|----------|
| Repo not resolved | Ask user, do not execute |
| Lock acquisition fails | Queue the task |
| opencode returns non-zero | Keep task in_progress, append error output as comment, notify user |
| opencode times out (600s) | Keep task in_progress, append "超时" comment, notify user |
| lark-cli update fails | Log warning, still notify user via message |
| Duplicate task event | Dedup cache drops it silently |

---

## Resolved Defaults

| Decision | Default | Rationale |
|----------|---------|-----------|
| Task cleanup | Leave completed tasks for manual cleanup | Avoid data loss; user can clean up at their pace |
| Rate limiting | No per-user limit initially | Keep simple; add if abuse observed |
| opencode model | Uses gateway default model | Consistent with rest of the system; can override via `--model` flag later |
