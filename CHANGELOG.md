# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-03-14

### Security

- **CRITICAL**: Added protected modules list in `upgrade_code` to prevent arbitrary code execution. Protected modules: `Security`, `UpgradeManager`, `CodeUpgrade`, `Tool.UpgradeCode`, `Tool.Registry`
- Fixed command blacklist bypass vulnerabilities in `Security.validate_command/1`:
  - Shell commands can no longer bypass via full path (`/bin/bash`, `/usr/bin/bash`)
  - Blocked shell escapes via `env`, `xargs`, `exec`, `nice`, `timeout` wrappers
  - Added detection for interpreter execution (`python -c`, `perl -e`, `ruby -e`, `node -e`, `php -r`)
  - Added detection for Python system calls (`os.system`, `subprocess`, `eval()`, `exec()`, `import os`)
- Added symlink escape detection in `Security.validate_path/1` to prevent path traversal via symbolic links
- Fixed Atom table memory leak in `Config.provider_to_atom/1` - now uses whitelist-based safe conversion

### Fixed

- **Memory leak** in `Bus.unsubscribe` - now properly calls `Process.demonitor/2` to clean up monitors
- **Memory leak** in `Subagent` - completed/failed/cancelled tasks now cleaned up (max 100 retained)
- **Race condition** in `Cron.save_jobs` - changed from async to synchronous file writes
- **DoS vulnerability** in `ListDir` - added recursion depth limit (10) and entry limit (5000)

### Changed

- `Config.provider_to_atom/1` now safely converts provider strings using a whitelist instead of `String.to_atom/1`
- `Security.validate_command/1` now extracts base command from full paths and handles inline comments
- Removed redundant `Path.expand` call in `Security.safe_traversal?/1`

## [0.1.0] - 2025-03-13

### Added

- Initial release
- Multi-channel support: Telegram, Feishu, Discord, Slack, DingTalk
- LLM provider support: OpenAI, Anthropic, OpenRouter, Ollama
- Tool system: read, write, edit, list_dir, bash, web search, memory management
- Self-evolution capability: code upgrade, tool creation, skill creation
- Session management with memory consolidation
- Scheduled tasks (cron) support
- Background subagent spawning