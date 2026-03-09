# NexAgent Todo List

This list is based on a code review of the current project state and focuses on the issues that most directly affect product credibility: safety, self-evolution, and long-running reliability.

## High Priority

- Wire `Security.validate_command/1` into the `bash` tool.
  Files:
  `lib/nex/agent/tool/bash.ex`
  `lib/nex/agent/security.ex`

- Make `bash` treat non-zero exit codes as errors instead of successful results.
  Right now failed shell commands are returned as `{:ok, ...}` and are easy for the agent to misread as successful.
  Files:
  `lib/nex/agent/tool/bash.ex`
  `lib/nex/agent/runner.ex`

- Fix `bash` timeout handling so the declared `timeout` tool parameter actually works.
  The definition exposes `timeout`, but execution currently reads timeout from `ctx`, not from tool arguments.
  File:
  `lib/nex/agent/tool/bash.ex`

- Remove or restrict direct `.ex` source edits through `write` and `edit`.
  Today they write source to disk first and only then attempt compilation, which leaves broken code behind when compilation fails.
  Route source-level changes through the `evolve` path instead, or add transactional rollback.
  Files:
  `lib/nex/agent/tool/write.ex`
  `lib/nex/agent/tool/edit.ex`
  `lib/nex/agent/tool/evolve.ex`

- Implement the protection promises around `Surgeon`.
  Current prompts and tool descriptions talk about canary protection and automatic rollback for core modules, but the implementation does not actually perform canary monitoring today.
  Files:
  `lib/nex/agent/surgeon.ex`
  `lib/nex/agent/tool/evolve.ex`
  `lib/nex/agent/context_builder.ex`

## Medium Priority

- Fix session GC in `Heartbeat`.
  Sessions are stored in per-session directories, but GC currently calls `File.rm/1` on the directory path, so old sessions are not actually removed.
  Files:
  `lib/nex/agent/heartbeat.ex`
  `lib/nex/agent/session.ex`

- Implement evolution cleanup in `Heartbeat`.
  The maintenance task is declared, but `run_evolution_cleanup/0` is still a stub.
  File:
  `lib/nex/agent/heartbeat.ex`

- Let CLI flows respect environment variable API keys.
  The library layer supports env fallbacks, but CLI validation currently blocks entry unless the key is written into config.
  Files:
  `lib/mix/tasks/nex.agent.ex`
  `lib/nex/agent/config.ex`
  `lib/nex/agent.ex`

- Reconcile self-evolution messaging with actual guarantees.
  README, prompts, and tool descriptions should not promise stronger safety properties than the current implementation can enforce.
  Files:
  `README.md`
  `README.zh-CN.md`
  `lib/nex/agent/context_builder.ex`
  `lib/nex/agent/tool/evolve.ex`

## Lower Priority

- Decide whether the HTTP channel is a real supported channel or an unfinished stub.
  It exists as a module, but it is not wired into `Gateway`, config validation, or onboarding flows.
  Files:
  `lib/nex/agent/channel/http.ex`
  `lib/nex/agent/gateway.ex`
  `lib/nex/agent/config.ex`

- Improve product polish around onboarding and channel configuration.
  Telegram already has CLI-level config support, while other chat apps still require manual config edits.
  Files:
  `lib/mix/tasks/nex.agent.ex`
  `lib/nex/agent/config.ex`

- Add stronger operational tests for long-running behavior.
  Focus areas:
  session persistence
  heartbeat cleanup
  cron isolation
  tool failure handling
  Files:
  `test/`
