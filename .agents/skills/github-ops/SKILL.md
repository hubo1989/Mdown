---
name: github-ops
description: GitHub issues, PRs, releases, and workflow inspection for Mdown via gh CLI.
version: 1.1.0
allowed-tools:
  - Bash
  - Read
---

# Mdown GitHub Operations

Use this skill when working with GitHub issues, pull requests, releases, or Actions runs for Mdown.

## Golden Rule

Always inspect live GitHub state with `gh` before acting.

## Common Commands

```bash
gh issue view 123
gh issue list --state open
gh pr view 123
gh pr diff 123
gh pr checks 123
gh release list
gh release view V1.0.0
gh run list --limit 10
gh run view <run-id>
```

## Safety Rules

- Do not comment on issues or PRs without explicit maintainer approval.
- Do not close issues, create PRs, merge, tag, or publish releases unless asked.
- Draft replies in the same language as the thread.
- For release publishing, use the release skill and verify version alignment first.

## Output

Summarize the GitHub state, proposed action, and the verification command or workflow status that supports it.
