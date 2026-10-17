# Follow-up — PR #63

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-10-17.

### NITPICK — stale compat comments / missing `@impl`
**Fixed.** Comments rewritten; `@impl PhoenixKit.Module` on `migrate_legacy/0`.

### NITPICK — dead `:requires_unreleased_core` tags
**Fixed.** Removed from `active_integration_test.exs`.

### IMPROVEMENT - MEDIUM — empty pre-existing connection suppresses migration
**Not changed.** Matches the behaviour the PR's test asserts; revisit if a host reports unmigrated legacy credentials.

### NITPICK — `resolve_via_list_connections/1` redundancy
**Not changed.**
