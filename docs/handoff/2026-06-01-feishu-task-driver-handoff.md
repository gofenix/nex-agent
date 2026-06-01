# Handoff: Feishu Task → OpenCode Driver

## What this is

A feature for nex-agent that lets users create Feishu (Lark) tasks and have the
agent dispatch them to the OpenCode CLI for coding work. Results flow back to
the task as comments and to the user as a chat message.

## Current state

- **Code is written, compiles, passes the relevant tests.** The implementation
  is on `main`, commits `b99fed6` → `76649cc` and the gateway is running
  (PID logged in `/tmp/nex-gateway.log`).
- **The pipeline is not end-to-end verified.** Task events from Feishu are
  not arriving at the WebSocket, so the dispatcher has never actually been
  exercised. The skill, lock, queue, and `lark-cli` integration are all
  written but untriggered.
- **Chat (IM) events work fine.** The bot replies to ordinary messages and
  processes them through the LLM loop normally.

## What was built

| Component | File | Status |
|-----------|------|--------|
| Event normalization + dedup | `lib/nex/agent/channel/feishu_task.ex` | Done |
| Feishu channel event branch | `lib/nex/agent/channel/feishu.ex` | Modified |
| Routing via `_from_feishu_task` | `lib/nex/agent/inbound_worker.ex` | Done |
| `force_skills` in context builder | `lib/nex/agent/context_builder.ex` | Done |
| `Skills.read_skill_instructions/1` | `lib/nex/agent/skills.ex` | Added |
| Runner passes `force_skills` | `lib/nex/agent/runner.ex` | Modified |
| Execution skill | `priv/skills/feishu-task-executor/SKILL.md` | Done |
| Repo alias registry | `~/.nex/agent/workspace/tasks/repos.json` | Seeded with `nex-agent` |

Spec and plan live at:

- `docs/superpowers/specs/2026-05-31-feishu-task-drive-opencode-design.md`
- `docs/superpowers/plans/2026-05-31-feishu-task-drive-opencode.md`

## The blocker

The Feishu app's WebSocket is alive but **task events never arrive**. Empirically:

- IM events (`im.message.receive_v1`, `im.message.reaction.*`,
  `im.message.message_read_v1`, `im.chat.access_event.*`) flow normally.
- Zero `task.task.*` events have been observed across multiple restarts.
- The user has confirmed (with screenshot) that task-related event
  subscriptions show as configured in the Feishu developer console:

  | Subscribed (per UI) | Status |
  |---------------------|--------|
  | `task.task.updated_v1` | Subscribed |
  | `task.task.comment.updated_v1` | Subscribed (covers create/update/delete per Feishu description) |
  | `task.task.update_tenant_v1` | Subscribed |
  | `task.task.update_user_access_v2` | Subscribed |

  | NOT subscribed |
  |----------------|
  | `task.task.created_v1` |
  | `task.task.comment.created_v1` |

- The app has full task permissions — the bot successfully creates tasks via
  `lark-cli task +create` (`task:task:write` confirmed in scope list).
- `GET /open-apis/application/v6/applications/<id>/app_versions` returns
  `items: []` — no published app versions. The user believes internal apps
  don't need publishing.
- The WebSocket endpoint query returns a stable `service_id=33554678` every
  restart; pongs are exchanged; the connection is healthy.

### Why this is weird

IM events were presumably subscribed for a long time and work. Task events were
added later and don't work. The most likely root causes, in order of
probability:

1. **Subscription activation is async or admin-gated.** The dev console UI
   shows a green checkmark but the actual subscription backend hasn't
   received or applied the change for this tenant. Some Feishu event types
   (especially task) may require explicit tenant-side admin approval that
   the UI doesn't make obvious.
2. **The WebSocket may not push `task.task.*` events for this app at all.**
   Some Feishu deployments route task/calendar/drive events through HTTP
   webhooks rather than the WebSocket long connection. The Feishu docs are
   not entirely clear on this.
3. **The user might have the wrong app open.** The user was uncertain who
   owns the app. Confirmed app identity: `nex` in tenant `Cosine` at
   `test-cftu6d3gqvmg.feishu.cn`. If the developer console they used is for
   a different tenant, the subscriptions would be inert.

## Environment

- **Feishu app**: `nex` (`cli_a92ef3be7938dbca`)
- **Tenant**: `Cosine` (`test-cftu6d3gqvmg.feishu.cn`)
- **OpenID of the human user**: `ou_5227397afd59865e471d94439ffff570`
- **App ID & secret**: stored in `~/.nex/agent/config.json` under
  `feishu.app_id` and `feishu.app_secret`
- **Gateway port**: `18790`
- **LLM provider** (for the agent's own reasoning, not for opencode):
  `openrouter` → OpenCode Go proxy, model `deepseek-v4-flash`
- **Repo alias**: `nex-agent` → `/Users/fenix/github/nex-agent`

To query the live config or app metadata at any time:

```bash
# Current config
cat ~/.nex/agent/config.json | python3 -m json.tool

# App info
APP_ID="cli_a92ef3be7938dbca"
APP_SECRET="kOi9J5wPVLfrEiBSTwYnzhpnPHOLJfGB"
TOKEN=$(curl -s -X POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal \
  -H "Content-Type: application/json" \
  -d "{\"app_id\":\"$APP_ID\",\"app_secret\":\"$APP_SECRET\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['tenant_access_token'])")

lark-cli api GET /open-apis/application/v6/applications/$APP_ID?lang=zh_cn

# Tenant info
lark-cli api GET /open-apis/tenant/v2/tenant/query --as bot | python3 -m json.tool

# Active WebSocket service_id
lark-cli api POST /open-apis/ws/v1/endpoint?type=event_callback --as bot \
  --data '{"AppID":"'"$APP_ID"'","AppSecret":"'"$APP_SECRET"'"}'
```

## How to operate

```bash
# Tail the live gateway log
tail -f /tmp/nex-gateway.log

# Look for task events specifically
grep "event_type=task\." /tmp/nex-gateway.log

# Look for any inbound
grep "Inbound sender=" /tmp/nex-gateway.log

# Restart the gateway (after config/code changes)
kill $(cat ~/.nex/agent/gateway.pid)
cd /Users/fenix/github/nex-agent
nohup mix nex.agent gateway > /tmp/nex-gateway.log 2>&1 &
```

## Next steps, in order

### 1. Confirm task events can ever reach this WebSocket

Before changing architecture, prove whether the WebSocket can deliver task
events at all. Two approaches:

**A. Check the Feishu docs explicitly for task event delivery over WebSocket.**

Read the "Open Platform / Event Subscriptions / WebSocket" page. Look for
any note that task events are webhook-only, or for a list of event types
explicitly supported by the long connection. If the docs say task events
require HTTP callback, that settles it.

**B. Add a second app with a brand new WebSocket from scratch, subscribe to
task events before first connection, and see if they arrive.** This is
expensive but definitive. If they arrive on a fresh app, the issue is stale
configuration on `nex`; if they don't, the WebSocket doesn't carry them
and we need webhook.

### 2. If the WebSocket cannot deliver task events

**Switch to an HTTP webhook** at `https://<host>/feishu/task-webhook`.
The gateway would need:

- A new HTTP route that receives task event POSTs from Feishu.
- A challenge-response handler for URL verification (`type: url_verification`).
- HMAC signature verification using the app's `encrypt_key` / `verification_token`.
- A small task to start a public tunnel (e.g., Cloudflare, ngrok) so Feishu
  can reach `127.0.0.1:18790`.
- Reuse the same `FeishuTask.normalize/1` logic on the incoming payload;
  the rest of the pipeline (dedup, inbound, runner, skill) is unchanged.

**Or, fall back to polling.** Cron a job every 30–60s that calls
`lark-cli task list --as user`, diffs against the last seen set, and
synthesizes `task.task.created_v1`-style inbound messages for new tasks.
Same downstream pipeline, no WebSocket dependency.

### 3. If the WebSocket CAN deliver task events, but for `nex` it doesn't

The most likely cause is stale subscription state. Try in order:

1. Disconnect the WebSocket for several minutes (kill the gateway, leave
   it down) so Feishu marks the connection as expired.
2. In the dev console, remove all task event subscriptions, save.
3. Re-add the three events (`task.task.updated_v1`,
   `task.task.comment.updated_v1`, `task.task.update_tenant_v1`),
   save.
4. Restart the gateway. Watch `WS event type=task.*` in the log.
5. If still nothing, ask the human to log into the **Cosine tenant admin
   console** (not just the dev console) and look for pending approvals.
   The human was uncertain who owns the app — admin approval is
   tenant-side.

### 4. End-to-end smoke test (when events finally flow)

Once the WebSocket starts emitting `task.*` events:

1. Create a task in Feishu UI with title "test: list repo files" and
   description "list the files in this repo". The `nex-agent` alias is
   pre-registered.
2. Confirm the gateway logs show:
   ```
   [Feishu] Task inbound id=... action=created
   ```
3. Confirm the Agent starts running and eventually calls
   `lark-cli task comment <id> --content '...'` and
   `lark-cli task update <id> --status completed`.
4. Reopen the task (or comment `/rerun` on it) and confirm the rerun path
   triggers.

If steps 2 or 3 fail, the bug is likely in the skill or in the lock/queue
implementation. Both were written but not exercised.

## Known fragility

- The dedup registry (`tasks/dedup.json`) has a 5-minute TTL. If Feishu
  replays an event after a process restart within that window, it is
  correctly dropped. Beyond the window it will fire again — by design.
- `bot_open_id` in the Feishu channel state comes from
  `Config.feishu_bot_open_id(config)`. The current value is whatever the
  user set in `config.json`; verify it's the bot's open_id (not the
  user's) before relying on it for self-event suppression.
- The skill uses `lark-cli` for all task operations. If `lark-cli` is not
  authenticated, every step 4–5 call will fail. The skill should ideally
  be re-triggered on `lark-cli` auth errors.
- The skill references `opencode -m ...`. The `opencode` binary must be
  on PATH for the gateway user.

## Files to read first

1. `docs/superpowers/specs/2026-05-31-feishu-task-drive-opencode-design.md`
2. `lib/nex/agent/channel/feishu_task.ex`
3. `priv/skills/feishu-task-executor/SKILL.md`
4. This document
