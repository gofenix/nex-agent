---
name: feishu-task-executor
description: Execute a Feishu task by dispatching it to opencode CLI for coding work. Reports results back to the task.
user-invocable: false
always: false
---

# Feishu Task Executor

You received a feishu task event. Your job: dispatch it to opencode for coding work, report results back to the task.

This is not a Nex personal task management request.

Forbidden:
- Do not use the internal `task` tool.
- Do not use `executor_status` or `executor_dispatch`.
- Do not inspect Nex executor runs unless the Feishu task explicitly asks for that.
- Do not answer conversationally before attempting the Feishu task execution workflow.

## Step 1: Parse the task

Extract from the incoming message metadata:
- task_id: the Feishu task ID
- task_title: the task title
- task_description: the task description (may be empty)
- task_action: "created" or "rerun"

If the visible message is only `/run_feishu_task <id>` or `/rerun_feishu_task <id>`,
use the ID from that command and fetch task details with `lark-cli task tasks get`.

## Step 2: Resolve the target repo

Try in priority order:

1. **Read the Feishu task custom field**: Use bash to call lark-cli and extract the "仓库" custom field value:
   ```
   bash("lark-cli task tasks get --as user --format json --params '{\"task_guid\":\"<task_id>\",\"user_id_type\":\"open_id\"}'")
   ```
   If it returns a valid path or known alias, use it.

2. **Parse @repo: from task description**: Look for `@repo: /path` or `@repo: alias-name` in task_description.

3. **Look up alias table**: Read `tasks/repos.json` in the workspace. Match any word from the task title/description against the keys.

4. **Ask the user**: If all above fail, send a message asking "不能确定任务 `<title>` 对应的仓库。请回复仓库路径或别名。". When the user replies, save the alias:
   ```
   bash("echo '\"<alias>\": \"<path>\"' >> tasks/repos.json")
   ```
   Then re-trigger the task by changing its status from completed to in_progress.

Store the resolved repo path as `REPO_PATH`.

## Step 3: Acquire repo lock

Use atomic mkdir to prevent concurrent execution on the same repo:
```
REPO_HASH=$(echo -n "<REPO_PATH>" | shasum -a 256 | cut -d' ' -f1)
LOCK_DIR="tasks/locks/$REPO_HASH"
mkdir "$LOCK_DIR" 2>/dev/null && echo '{"task_id":"<task_id>","started_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$LOCK_DIR/meta.json"
```

Execute as a single bash command:
```
bash("REPO_HASH=... LOCK_DIR=... mkdir ...")
```

If mkdir fails (lock is held):
1. Append to `tasks/queues/pending.jsonl`: `{"task_id":"<task_id>","repo":"<REPO_PATH>","enqueued_at":"<now_iso>"}`
2. Reopen the task if needed: `bash("lark-cli task +reopen --as user --task-id <task_id>")`
3. Add a comment: `bash("lark-cli task +comment --as user --task-id <task_id> --content '排队中，前面的任务完成后自动执行。'")`
4. STOP — do not proceed further.

## Step 4: Execute opencode

Reopen the task if it is completed (unless already done in Step 3):
```
bash("lark-cli task +reopen --as user --task-id <task_id>")
```

Run opencode with the task title and description as the prompt:
```
bash("cd <REPO_PATH> && opencode run --dangerously-skip-permissions '<task_title>: <task_description>' 2>&1", timeout: 1800)
```

Capture both exit code and output:
```
if cd "<REPO_PATH>" && opencode run --dangerously-skip-permissions "<task_title>: <task_description>" 2>&1; then EXIT_CODE=$?; else EXIT_CODE=$?; fi
echo "EXIT_CODE=$EXIT_CODE"
```

Use the larger timeout (at least 1800) since coding tasks can take a while. Check the EXIT_CODE from the output — 0 means success.

## Step 5: Report results

**If opencode succeeded (exit code 0):**
1. Update task status to completed: `bash("lark-cli task +complete --as user --task-id <task_id>")`
2. Add a comment with output summary (first 500 characters, trim to avoid API limits):
   ```
   bash("lark-cli task +comment --as user --task-id <task_id> --content '执行完成。\n\n<output_summary>'")
   ```
3. Notify the user with a brief message + task link.

**If opencode failed (non-zero exit code):**
1. Keep task status as in_progress (so user can see and re-open it later).
2. Add a comment with the error output: `bash("lark-cli task +comment --as user --task-id <task_id> --content '执行失败。\n\n<error_output>'")`
3. Notify the user with the error info.

## Step 6: Release lock + dequeue

Release the lock:
```
bash("rm -rf tasks/locks/$REPO_HASH")
```

Check if there are queued tasks for the same repo:
```
bash("cat tasks/queues/pending.jsonl 2>/dev/null")
```

If entries exist for this repo:
1. Dequeue the first matching entry
2. Extract its task_id and other fields
3. Format a new task content as `/run_feishu_task <dequeued_task_id>`
4. Set `_from_feishu_task: true` in metadata (through the task_action mechanism)
5. Return to Step 2 for this dequeued task

If no queued tasks, you are done.
