---
name: code-review
description: Mdown project adapter for Waza check/code-review. Use for Swift, AppKit, iOS target, and release-safety review.
version: 1.1.0
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
disable-model-invocation: true
---

# Mdown Code Review Adapter

Use Waza `/check` for the generic review method. This adapter adds Mdown-specific commands, hard stops, and target awareness.

## Quick Commands

```bash
# View PR diff
gh pr diff 123

# Build check
xcodebuild -project Mdown.xcodeproj -scheme Mdown -configuration Debug build

# Lint
swiftlint lint --strict

# Format check
swift-format lint --recursive . --strict
```

## Mdown-Specific Checks

- [ ] No retain cycles (weak/unowned used correctly)
- [ ] Main thread UI updates only
- [ ] File I/O uses proper error handling
- [ ] No force unwraps (`!`) without justification
- [ ] Follows existing patterns in the codebase
- [ ] No unnecessary class where struct suffices
- [ ] Uses Swift concurrency correctly (async/await, actors)
- [ ] Keep the macOS editor core, preview pipeline, and existing storyboard scenes on AppKit; new self-contained panels may host SwiftUI through `NSHostingView`. `MdownMobile/` uses SwiftUI, without sharing UI layers across targets
- [ ] SwiftLint passes: `swiftlint lint --strict`
- [ ] No dead code or commented-out blocks
- [ ] Clear naming, no abbreviations
- [ ] No new external network calls without user consent
- [ ] File writes are scoped to user documents or app-controlled locations
- [ ] No shell injection in CLI-related code
- [ ] Changes under `MdownMobile/` consider target membership, sync behavior, and mobile resource paths

## Review Output Format

Follow Waza `/check`: findings first, ordered by severity, with tight file/line references. Keep summaries brief.

## Safety Rules

1. **NEVER** post review comments without explicit user request.
2. **ALWAYS** prepare feedback for user review first.
3. Draft responses in the same language as the PR author.
