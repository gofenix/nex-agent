---
name: code-review
description: Review code changes with a focus on bugs, regressions, and missing tests.
always: false
user-invocable: true
---

# Code Review

Use this skill when the user asks for a review of code, a diff, or a change set.

## Review Priorities

Focus on:

- behavioral regressions
- correctness bugs
- missing validation or error handling
- test gaps
- migration or compatibility risks

## Output Format

Present findings first, ordered by severity. Include file paths and line numbers when available. Keep summaries brief.

If no issues are found, say that explicitly and note any residual testing gaps.
