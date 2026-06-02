# Handoff: GitHub Projects V2 → OpenCode Driver

## What this is

Replace the broken Feishu task pipeline with GitHub Projects V2. The user creates Issues (labeled `opencode`) and drops them into a Project board. The agent polls the board, picks up items in the "Todo" column, dispatches to OpenCode for execution, creates a PR, and moves the item through a state machine ("Todo → Doing → In Review → Done"). The GitHub Project is the single source of truth for task state.

## Current state

**Nothing has been built yet.** The design is agreed upon but zero code has been written. This is a fresh start — the Feishu implementation (`feishu_task.ex`, `feishu-task-executor` skill, etc.) has been written and tested separately but is not part of this handoff. The Feishu pipeline is on hold because WebSocket task event subscriptions don't work.

**The single blocker:** the `gh` CLI token needs `read:project` scope before any Project V2 API calls work. The user attempted `gh auth refresh -h github.com -s project` but the actual required scope is `read:project`. They need to run:

```bash
gh auth refresh -h github.com -s read:project
```

## Environment

| Item | Value |
|------|-------|
| GitHub user (active) | `gofenix` (note: **GoFenix**, not GoPhoenix) |
| GitHub user (inactive) | `HarveySang` |
| Token scopes (current) | `admin:public_key`, `gist`, `read:org`, `repo`, `workflow` |
| Needed scope | `read:project` (for queries) — optionally `project` (for writes) |
| Project URL | `https://github.com/users/gofenix/projects/2` |
| NexAgent config | `~/.nex/agent/config.json` |
| Gateway port | `18790` |
| LLM provider | `openrouter` → `https://opencode.ai/zen/go/v1`, model `deepseek-v4-flash` |
| `gh` CLI path | `/opt/homebrew/bin/gh` |
| NexAgent repo | `/Users/fenix/github/nex-agent` |

Verify scopes after adding `read:project`:

```bash
gh auth status 2>&1 | grep "Token scopes"
```

Verify Project access:

```bash
gh project view 2 --owner gofenix --format json
gh project item-list 2 --owner gofenix --format json
gh project field-list 2 --owner gofenix --format json
```

## The state machine

```
┌──────────┐    ┌──────────┐    ┌───────────┐    ┌──────────┐
│   Todo   │ -> │  Doing   │ -> │ In Review  │ -> │   Done   │
│          │    │          │    │           │    │          │
│ Issue    │    │ Agent    │    │ PR 已提   │    │ Issue    │
│ 拖入     │    │ 认领     │    │ 等 merge  │    │ 关闭     │
│ 即触发   │    │ 执行     │    │           │    │ 结束     │
└──────────┘    └──────────┘    └───────────┘    └──────────┘
     ▲                                                 │
     └── PR closed (not merged) ───────────────────────┘
```

| # | 当前列 | 动作 | 目标列 |
|---|--------|------|--------|
| 1 | Todo | Agent 认领 → `cd <repo>` → `opencode -m "Fix #N: <title>"` → `gh pr create` | In Review |
| 2 | In Review, PR merged | `gh issue close <num>` → `gh project item-edit` 移列 → `gh issue comment <num> "✅ Done"` | Done |
| 3 | In Review, PR closed | `gh project item-edit` 移回 → `gh issue comment <num> "PR closed, re-opening"` | Todo |
| 4 | Done | 终态，不再轮询 | — |

## Architecture

### Components to build

| File | Purpose | Est. lines |
|------|---------|------------|
| `lib/nex/agent/channel/github_project_poller.ex` | **New module.** Polls Project V2, maintains a state registry (`tasks/github_items.json`), produces inbound messages with `_from_github_project: true` metadata. Runs via cron every 30s. | ~150 |
| `lib/nex/agent/inbound_worker.ex` | **Modify.** Add `_from_github_project` handling — force `github-issue-executor` skill, suppress outbound unless `message` tool is used, skip consolidation. Follow the existing `_from_cron` and `_from_feishu_task` patterns (lines ~250-270). | ~15 |
| `lib/nex/agent/channel/feishu_task.ex` | **Leave as-is.** Do NOT remove the Feishu code — it's stable and will work if/when WebSocket subscriptions are fixed. | 0 |
| `priv/skills/github-issue-executor/SKILL.md` | **New skill.** Guides the agent through the state machine. Step 1: claim the item (move to Doing), resolve the repo from the Issue, start opencode. Step 2: create a PR. Step 3: poll PR status, close issue, move to Done. | ~100 |
| `~/.nex/agent/config.json` | **Add** `github_project` block: `{"owner": "gofenix", "project_number": 2, "poll_interval_seconds": 30}` | ~5 |
| `tasks/github_items.json` | **Runtime.** State registry: `{"item_id": {"issue_url": ..., "repo": ..., "status": ..., "claimed_at": ..., "pr_url": ...}}`. Auto-managed by Poller. | auto |

### How the poller works

```elixir
defmodule Nex.Agent.Channel.GithubProjectPoller do
  # Called by cron job every 30s

  def poll(config) do
    # 1. gh project item-list <N> --owner <owner> --format json
    #    Extract each item's: id, content (issue URL/number), column name, repo

    # 2. Load tasks/github_items.json (state registry)

    # 3. For each item in "Todo" that is NOT in the registry:
    #    - Write to registry with status: :claimed
    #    - Publish Bus.publish(:inbound, %{metadata: %{
    #        _from_github_project: true,
    #        item_id: ...,
    #        issue_url: ...,
    #        issue_title: ...,
    #        issue_body: ...,
    #        repo: ...,
    #        action: :pickup
    #      }})

    # 4. For each item in "In Review":
    #    - Look up registry for pr_url
    #    - gh pr view <pr_url> --json state,merged
    #    - If merged → publish inbound with action: :complete
    #    - If closed (not merged) → publish inbound with action: :abandon

    # Items in "Done" or "Doing" (already claimed) are skipped
  end
end
```

### How the agent should be invoked

When the cron fires, the poller publishes an inbound message that looks like:

```
channel: "github",
chat_id: "gofenix",
content: "Pick up Issue #<N>: <title>",
metadata: {
  _from_github_project: true,
  item_id: "PVTI_...",
  issue_url: "https://github.com/<owner>/<repo>/issues/<N>",
  issue_title: "...",
  issue_body: "...",
  repo: "<owner>/<repo>",
  repo_path: "/Users/fenix/github/<repo>",   # resolved via alias
  action: "pickup" | "complete" | "abandon"
}
```

The InboundWorker routes `_from_github_project` to force-load `github-issue-executor` skill and suppress text outbound (same as cron/feishu-task patterns).

### Repo path resolution

The Issue tells us the `<owner>/<repo>` name. To get a local path, we need a mapping. Use the same alias system as Feishu but with GitHub repos:

```json
// tasks/repos.json
{
  "gofenix/nex-agent": "/Users/fenix/github/nex-agent",
  "gofenix/my-project": "/Users/fenix/github/my-project"
}
```

When the poller encounters a new repo not in the table, it should publish an inbound that asks the user for the path, and the user's reply gets recorded.

### Skill: github-issue-executor

The skill guides the agent through these steps:

```
Action: pickup
  1. gh issue view <num> --repo <repo>  → 获取标题+正文
  2. gh project item-edit <item_id> --field-id Status --single-select-option-id <Doing>
  3. cd <repo_path> && gh issue checkout <num>
  4. opencode -m "Resolve GitHub Issue #<num> on <repo>: <title>. <body>.
     After making changes, run tests. When done, use 'gh pr create' to open a PR."
  5. 记录 PR URL 到 registry file: tasks/github_items.json

Action: complete
  1. gh issue close <num> --repo <repo> --comment "✅ Done via OpenCode"
  2. gh project item-edit <item_id> --field-id Status --single-select-option-id <Done>

Action: abandon
  1. gh project item-edit <item_id> --field-id Status --single-select-option-id <Todo>
  2. gh issue comment <num> --repo <repo> --body "PR was closed without merging. Re-opening."
```

### Registry format

```json
{
  "PVTI_xxxxx": {
    "issue_url": "https://github.com/gofenix/repo/issues/1",
    "repo": "gofenix/repo",
    "repo_path": "/Users/fenix/github/repo",
    "status": "doing",
    "claimed_at": "2026-06-01T12:00:00Z",
    "pr_url": null,
    "last_check": "2026-06-01T12:05:00Z"
  }
}
```

## How to operate

```bash
# Tail the live gateway log
tail -f /tmp/nex-gateway.log

# Watch for GitHub project events
grep "github_project\|GithubProject\|_from_github" /tmp/nex-gateway.log

# Look at the state registry
cat ~/.nex/agent/workspace/tasks/github_items.json | python3 -m json.tool

# Query the project directly
gh project item-list 2 --owner gofenix --format json
gh project field-list 2 --owner gofenix --format json

# Restart the gateway
kill $(cat ~/.nex/agent/gateway.pid)
cd /Users/fenix/github/nex-agent
nohup mix nex.agent gateway > /tmp/nex-gateway.log 2>&1 &

# Run tests (always do before implementing)
mix test test/nex/agent/config_test.exs test/nex/agent/llm/req_llm_test.exs
```

## Prior art in the codebase to reference

| Pattern | File | Lines | What it does |
|---------|------|-------|--------------|
| `_from_cron` routing | `inbound_worker.ex` | 254-300 | Detects cron metadata, applies special opts (skip_skills, max_iterations:3, skip_consolidation) |
| `_from_feishu_task` routing | `inbound_worker.ex` | 253+ | Detects feishu task metadata, applies `force_skills: ["feishu-task-executor"]` |
| `Bus.publish(:inbound, ...)` | `cron.ex` | ~400 | How cron jobs inject messages into the agent pipeline |
| `force_skills` in Runner | `runner.ex` | 73-76 | How Runner passes forced skills to ContextBuilder |
| `force_skills` in ContextBuilder | `context_builder.ex` | 225-247 | Loads specific skill by name instead of always-skills |
| Feishu task event normalizer | `feishu_task.ex` | 1-145 | Analogous normalizer for task events; poller is simpler |
| Skill format | `priv/skills/feishu-task-executor/SKILL.md` | 1-116 | Template for the new github skill |
| Skill reading | `skills.ex` | ~200 | `read_skill_instructions/1` for loading a skill by name |

## Implementation sequence

1. **Unblock**: User runs `gh auth refresh -h github.com -s read:project`. Verify with `gh project view 2 --owner gofenix`.

2. **Explore the Project**: Before writing code, run these to understand the exact field names, column option IDs, and item content types:
   ```bash
   gh project field-list 2 --owner gofenix --format json
   gh project item-list 2 --owner gofenix --format json
   gh project view 2 --owner gofenix --format json
   ```
   The column names, field IDs, and single-select option IDs are critical — the code must match exactly.

3. **Add config**: Add `github_project` to `config.json`.

4. **Build the poller**: `github_project_poller.ex` — poll + registry + inbound message generation.

5. **Add routing**: `inbound_worker.ex` — `_from_github_project` detection + opts.

6. **Write the skill**: `priv/skills/github-issue-executor/SKILL.md`.

7. **Seed repo alias**: Add the user's repos to `tasks/repos.json`.

8. **Register the cron job**: Have the gateway auto-register a 30s cron on startup (or document that the user needs to run a one-time setup command).

9. **Test end-to-end**: Create an Issue, add to Project Todo column, watch the logs.

## Known unknowns

- **Field names on Project/2 are unknown.** We don't know what the "Status" field is called, what the column options are named, or what their IDs are. This must be discovered in step 2 above.
- **Item content format is unknown.** When an Item is an Issue, does `gh project item-list` include the Issue number/title inline, or do we need `gh issue view` separately?
- **`gh project item-edit` field IDs.** The command requires `--field-id` and `--single-select-option-id` — these are opaque GraphQL IDs, not names. We need to map them.
- **Repo resolution strategy.** Does the Issue item in the Project carry the repo name automatically, or do we need to parse `issue_url`?
