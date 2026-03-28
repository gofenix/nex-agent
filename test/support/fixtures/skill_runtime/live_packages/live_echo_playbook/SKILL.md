---
name: live-echo-playbook
description: Echo a task string for live SkillRuntime end-to-end verification.
execution_mode: playbook
entry_script: scripts/run.sh
parameters:
  type: object
  properties:
    task:
      type: string
---

Use this playbook only for live SkillRuntime end-to-end verification. It echoes the provided task string.
