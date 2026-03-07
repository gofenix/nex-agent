# NexAgent Improvement Implementation Log

Implementation checklist based on the NexAgent vs Nanobot comparison analysis.

---

## Repository Strategy

- Keep `nex_agent` inside the `nex` monorepo for now.
- Current coupling is mainly at the ecosystem level: examples, showcase apps, and shared release narrative.
- Technical extraction is still feasible later because direct package-level coupling remains limited.
- Re-evaluate a repository split only when release cadence, documentation entry points, and product identity become independently stable.

---

## Completed Improvements

### High Priority

#### 1. Tool hardening — Bash command blacklist

**File**: `lib/nex/agent/tool/bash.ex`

**Change**: The Bash tool now calls `Security.validate_command()` before executing commands.

```elixir
def execute(%{"command" => command}, ctx) do
  case Security.validate_command(command) do
    :ok -> do_execute(command, ctx)
    {:error, reason} -> {:error, "Security: #{reason}"}
  end
end
```

Blocked dangerous patterns include:
- System directory deletion (`rm -rf /usr`, `rm ~/`)
- Disk operations (`dd if=/dev/`, `mkfs`, `fdisk`)
- System control (`shutdown`, `reboot`, `poweroff`)
- Fork bombs (`:(){:|:&};:`)
- Infinite loops (`while true...done`)
- Remote code execution (`curl | sh`, `eval $(curl`)
- Credential theft (`cat ~/.ssh/`, `cat .env`, `cat *.pem`)
- Network exfiltration (`curl -d @file`, `nc -l`)
- Cron tampering (`crontab -`)

#### 2. Workspace sandbox — file read/write path restrictions

**Files**: `lib/nex/agent/tool/read.ex`, `lib/nex/agent/tool/write.ex`, `lib/nex/agent/tool/edit.ex`

**Change**: All file operation tools now call `Security.validate_path()` before execution, and the path must be inside one of the following allowed roots:
- Project directory (`File.cwd!()`)
- Agent workspace (`~/.nex/agent`)
- Temporary directory (`/tmp`)

The allowed roots can be extended via the `NEX_ALLOWED_ROOTS` environment variable.

#### 3. Enhanced dangerous-pattern coverage in `Security.ex`

**File**: `lib/nex/agent/security.ex`

**Changes**:
- Dangerous command patterns increased from 8 to 30+
- The command allowlist increased from about 40 to about 80, covering more developer tools
- Added support for `bun`, `deno`, `go`, `ruby`, `gem`, `java`, `gradle`, `mvn`, `jq`, `yq`, `tar`, `zip`, `base64`, and more

#### 4. New channel — Discord

**File**: `lib/nex/agent/channel/discord.ex`

**Implementation**:
- WebSocket Gateway API (v10) integration
- Heartbeat maintenance plus identify/resume flow
- Supports both DM and group `@mention` triggers
- 2000-character message chunking
- Automatic rate-limit retry
- `allow_from` channel allowlist

**Configuration**:
```json
{
  "discord": {
    "enabled": true,
    "token": "Bot MTIz...",
    "allow_from": [],
    "guild_id": null
  }
}
```

#### 5. New channel — Slack

**File**: `lib/nex/agent/channel/slack.ex`

**Implementation**:
- Receives events via Socket Mode (WebSocket)
- Sends messages through the Web API
- Supports `message` and `app_mention` events
- Thread replies via `thread_ts`
- Automatic bot identity detection

**Configuration**:
```json
{
  "slack": {
    "enabled": true,
    "app_token": "xapp-...",
    "bot_token": "xoxb-...",
    "allow_from": []
  }
}
```

#### 6. New channel — DingTalk

**File**: `lib/nex/agent/channel/dingtalk.ex`

**Implementation**:
- Receives bot messages through the Stream Mode API
- OAuth2 access-token management with automatic refresh
- Session webhook preferred for replies, Robot API as fallback
- Supports both direct chat and group chat

**Configuration**:
```json
{
  "dingtalk": {
    "enabled": true,
    "app_key": "ding...",
    "app_secret": "...",
    "robot_code": "ding...",
    "allow_from": []
  }
}
```

#### 7. New tool — ListDir

**File**: `lib/nex/agent/tool/list_dir.ex`

**Implementation**:
- Lists directory contents including file type, size, and modification time
- Supports recursive listing with `recursive: true`
- Paths are validated by the Security sandbox

**Tool definition**:
```json
{
  "name": "list_dir",
  "parameters": {
    "path": "directory path",
    "recursive": "whether to recurse (default: false)"
  }
}
```

### Integration Changes

#### `Config.ex` expansion

**File**: `lib/nex/agent/config.ex`

Added `discord`, `slack`, and `dingtalk` configuration sections, including:
- Struct fields
- Default values
- Getter/setter methods
- Configuration validation via `valid?/1`
- Serialization and deserialization

#### `Gateway.ex` expansion

**File**: `lib/nex/agent/gateway.ex`

- Added `ensure_discord_channel_started/1`
- Added `ensure_slack_channel_started/1`
- Added `ensure_dingtalk_channel_started/1`
- Added matching `stop_*_channel/0` functions
- `status/0` now returns the new channel statuses

#### Tool registry expansion

**File**: `lib/nex/agent/tool/registry.ex`

- Added `Nex.Agent.Tool.ListDir` to `@default_tools`
- Default tool count increased from 15 to 16

---

## Future Improvement Directions

### Medium Priority

| # | Improvement | Notes |
|---|------|------|
| 1 | **LiteLLM Integration** | Consider using LiteLLM's HTTP bridge to expand provider coverage |
| 2 | **Provider Registry** | Unified provider metadata such as API key prefix detection and model-name mapping |

### Low Priority

| # | Improvement | Notes |
|---|------|------|
| 3 | **Cron Tool** | Let the agent create scheduled tasks autonomously through a tool interface, since the Cron GenServer already exists |
| 4 | **More Channels** | WhatsApp, QQ, Matrix, Email |
