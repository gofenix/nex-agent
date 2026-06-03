---
name: github-issue-executor
description: Handle GitHub issue or PR comments that mention NexAgent, using the comment and repository context to decide whether to start, continue, retry, stop, report status, or ask for clarification.
user-invocable: false
always: false
---

# GitHub Issue Executor

You received a GitHub comment mention event. Your job is to understand the user's natural-language comment in the current issue or PR context, then take the appropriate GitHub and local execution steps.

This is not a chat request, Feishu task, Nex personal task request, or keyword command parser. Do not look for rigid commands such as `run`, `revise`, `retry`, or `stop`. Infer intent from the comment plus issue, PR, registry, branch, work_dir, and recent execution context.

Forbidden:
- Do not use Feishu or `lark-cli`.
- Do not use the internal `task` tool.
- Do not use `executor_status` or `executor_dispatch`.
- Do not implement issue changes yourself with read/edit/write tools.
- Do not inspect the repository at length before deciding whether coding work is needed.
- Do not execute risky or ambiguous requests; ask a concise GitHub comment question instead.

## Step 1: Parse Metadata

Extract these fields from the incoming metadata when present:
- event_type
- issue_url, issue_number, issue_title, issue_body
- repo: GitHub repo such as `gofenix/nex-agent`
- work_dir: disposable local checkout path
- branch: branch to use inside the disposable checkout
- pr_url: existing pull request URL
- comment_body, comment_url, comment_author
- registry entry or previous run summary

If the visible message conflicts with metadata, trust metadata.

## Step 2: Decide The Next Move

Use the comment and GitHub context to decide what to do.

Examples:
- The issue has no open PR and the user asks NexAgent to handle the issue: start implementation work.
- There is an open PR and the user says something is wrong or asks for a change: continue on the existing branch/PR.
- The last execution failed and the user says the blocking condition is fixed or asks to try again: retry the relevant step.
- The user asks to stop, pause, or abandon current work: stop local execution if possible and leave a clear GitHub comment.
- The user asks for progress: inspect local registry/PR state and report status.
- The user's intent is unclear or high-risk: ask one concise clarifying question in GitHub.

Do not require or invent an `action` metadata field.

## Step 3: Prepare Work Directory

If coding work is needed:
1. Validate `work_dir` exists or can be prepared from metadata.
2. Refuse to run if `work_dir` is under `/Users/fenix/github/` or `/Users/fenix/repos/`; those are long-lived checkouts.
3. Read the target repo's local instructions, especially `AGENTS.md`, before dispatching.
4. Switch/create the branch from metadata, or continue the existing PR branch.
5. Inspect the issue and PR enough to build the execution prompt:

```bash
cd "$WORK_DIR"
git switch -C "$BRANCH"
gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body,state,labels,url
gh pr view "$PR_URL" --json title,body,state,headRefName,url
```

## Step 4: Dispatch Coding Work

Dispatch implementation work with the `opencode_run` tool. This is mandatory for code changes. Do not implement the issue yourself.

The nested opencode prompt must include:
- the issue title/body
- the existing PR context, if any
- the user's latest comment
- a clear instruction not to commit, push, or create a PR
- the narrowest useful verification expectation

Use:

```text
opencode_run(work_dir: "$WORK_DIR", branch: "$BRANCH", repo: "$REPO", issue_number: ISSUE_NUMBER, issue_title: "$ISSUE_TITLE", issue_body: "$ISSUE_BODY", model: "$OPENCODE_MODEL", timeout: 1800)
```

## Step 5: Publish Results

After `opencode_run` returns:
1. Inspect the result JSON, stdout/stderr log, git diff summary, and local git diff.
2. Run any missing narrow verification yourself.
3. If changes are valid, commit and push the branch.
4. Create a PR if none exists, or update the existing PR branch.
5. Comment on the issue or PR with a concise result and verification summary.
6. Record useful state in `tasks/github_items.json`, including `repo`, `issue_number`, `pr_url`, `work_dir`, `branch`, `last_comment_url`, and `last_check`.

```bash
cd "$WORK_DIR"
git status --short
gh pr list --repo "$REPO" --search "$ISSUE_NUMBER" --json url,number,title,state,headRefName --limit 10
git add <changed files>
git commit -m "Update GitHub issue #$ISSUE_NUMBER"
git push -u origin "$BRANCH"
gh pr create --repo "$REPO" --title "$ISSUE_TITLE" --body "Refs #$ISSUE_NUMBER"
```

If the user asked to stop or the intent is unclear, do not run `opencode_run`; leave a GitHub comment explaining the current state or asking for the missing decision.
