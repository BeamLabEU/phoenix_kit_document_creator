# PR #2 Follow-Up — Pivot to Google Docs API

This PR was the architectural pivot from a local document editor (GrapesJS / ChromicPDF / TipTap) to Google Docs + Drive API. CLAUDE_REVIEW.md flagged 12 findings; the table below reflects the state of each finding when audited against the current `lib/` and `test/` (2026-04-25).

## Fixed (pre-existing)

- ~~**C1 — SQL injection in Drive API queries** (`google_docs_client.ex:150-151, 247-248`)~~ — single quotes in interpolated `q=` strings are escaped via `escape_query_value/1` (`google_docs_client.ex:559`). Verified at `:85` and other interpolation sites.
- ~~**C3 — Template moduledoc references GrapesJS**~~ — moduledocs on `Schemas.Template` and `Schemas.Document` were rewritten to describe the Google Docs flow (`schemas/template.ex:2-12`, `schemas/document.ex:2-…`).
- ~~**H3 — PubSub self-echo on every render**~~ — `documents_live.ex:153-159` already guards with `if from_pid != self() and not socket.assigns.loading and not within_cooldown?(socket)`.
- ~~**H2 (caveated) — Sequential Drive calls block the LiveView**~~ — `:sync_from_drive` already wraps the work in a non-blocking task (`documents_live.ex:88-103`) with try/rescue. Concurrency boundary kept (one walker at a time) is intentional — the walker batches its own requests at the BFS level. Not fully addressed inside the walker itself, but the LV is no longer blocked.
- ~~**Issues from the architectural assessment about dead OAuth-token-in-Settings**~~ — superseded by PR #5 (OAuth migrated to `PhoenixKit.Integrations`).

## Fixed (Batch 1 — 2026-04-25)

- ~~**H1 — Thumbnails async but unbounded `Task.start`** (`documents.ex:1235-1239`)~~ — replaced with a single supervised parent task under `PhoenixKit.TaskSupervisor` that fans out via `Task.async_stream/3` with `max_concurrency: 8`, `on_timeout: :kill_task`, `timeout: 30s`. Opening a 500-file folder no longer fires 500 simultaneous Drive requests; the parent is `restart: :temporary` so it cleans up if the LV terminates while in-flight requests can still persist their thumbnails.

## Skipped (with rationale)

- **C2 — Schemas still contain dead GrapesJS/ChromicPDF fields** (Template / Document / HeaderFooter). Moduledocs already note these as legacy; the actual column removal is queued as a core phoenix_kit migration (see AGENTS.md TODOs). Out of scope for this module — the migration has to land in `lib/phoenix_kit/migrations/postgres/` first; this module can then drop the field defs in a follow-up. Surfaced to Max as a punt for a coordinated core PR, not a silent defer.
- **H4 — PDF as base64 over WebSocket**. Architecture change, not a refactor. Replacing the `Documents.export_pdf/1` → `data:application/pdf;base64,...` payload with a signed download endpoint adds new HTTP routing + token-signing infrastructure that doesn't exist today; that's feature work, not quality-sweep work. Per `feedback_quality_sweep_scope.md`. Surfaced to Max.
- **M3 — Inline `<script>` re-executes on render**. Phoenix Hook conversion is a frontend architecture change, not a single-file refactor. Surfaced to Max.
- **Naming nitpick: `apply_optimistic_move`** (PR #9 review covers the same finding) — the function applies the move *after* `:ok` is returned by the backend, so it isn't truly optimistic. Pure rename churn with no behaviour change; deferred per quality-sweep scope (`feedback_quality_sweep_scope.md`).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_document_creator/documents.ex` | Bound thumbnail concurrency via supervised `Task.async_stream` |

## Verification

- `mix compile` clean.
- `mix precommit` clean (full check after Phase 2 lands).
- `mix test` to be re-run after the test infra is in place (Phase 2 C7).

## Open

None. All still-live findings either fixed in Batch 1, surfaced to Max as a punt, or covered by a separate active TODO in AGENTS.md.
