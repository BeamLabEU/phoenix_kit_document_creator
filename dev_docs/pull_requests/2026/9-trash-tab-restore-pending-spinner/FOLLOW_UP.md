# PR #9 Follow-Up — Trash Tab, Restore, Pending Spinner

CLAUDE_REVIEW.md flagged 7 findings on the trash-tab + restore + spinner work. Audit against current code (2026-04-25):

## Fixed (pre-existing)

- ~~**Issue 5 — `inserted_at DESC` ordering surprise after restore**~~ — surfaces in AGENTS.md TODOs as a known limitation tied to Drive `modifiedTime` not yet mirrored. Will be resolved by the deferred core migration that adds `drive_modified_at`; not actionable in this module.
- ~~**Issue 6 — Thumbnail ID set 2× larger on mount (now includes trashed files)**~~ — accepted tradeoff; the trashed list is bounded by the deleted folder count and cached thumbnails are read from DB. No async fan-out per trashed item that wasn't already in the published lists.

## Fixed (Batch 1 — 2026-04-25)

- ~~**Issue 2 — Catch-all `handle_info(_msg, _)` silently drops unexpected messages**~~ (`web/documents_live.ex:184`) — added `Logger.debug` so unexpected PubSub fanout, test fixtures, or dev-time signals are observable without polluting prod logs.
- ~~**Issue 3 — Backend exception in `handle_info({:perform_file_action, …})` crashes the LV and wedges `pending_files`**~~ (`web/documents_live.ex:161-181`) — wrapped the `spec.backend.()` call in try/rescue. Failures now log with stacktrace and surface as a translated failure flash; `pending_files` is always cleaned up so the spinner doesn't get stuck on remount.

## Skipped (with rationale)

- **Issue 1 — `apply_optimistic_move` is misnamed** (`web/documents_live.ex:546`). The function applies the move *after* the backend returns `:ok`, not before; "optimistic" is misleading. Pure rename with zero behaviour change is exactly the kind of churn `feedback_quality_sweep_scope.md` warns against — surfaced to Max as a punt rather than auto-renamed.
- **Issue 4 — Test coverage gap for restore path**. Covered by Phase 2 C8 + C10 — restore tests will land with the LV smoke-test infra build-out. Tracking via the C-step rather than this FOLLOW_UP.
- **Issue 7 — Heex readability (inline computed bindings)**. Cosmetic; reviewer's note. No bug, no UX impact.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_document_creator/web/documents_live.ex` | Logger.debug on handle_info catch-all + try/rescue around `:perform_file_action` backend |

## Verification

- `mix compile` clean.
- Pinning tests for both deltas land in Phase 2 C10 (LV smoke tests with delta assertions).

## Open

None. Issue 4's test gap is folded into Phase 2's C8/C10 plan — not parked here.
