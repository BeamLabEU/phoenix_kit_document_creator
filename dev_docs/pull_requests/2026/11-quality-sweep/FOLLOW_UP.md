# PR #11 Follow-Up — Quality sweep + re-validation

PR #11 is the module-wide quality sweep on top of `BeamLabEU:main`.
The original sweep (Phase 1 + Phase 2) shipped 2026-04-25. Batch 2
re-validation 2026-04-26 against the post-Apr workspace AGENTS.md
pipeline closed the structural deltas the original sweep predates.

## Original sweep — 2026-04-25 (canonical batch)

Phase 1 — PR triage. Eight prior PRs (#1, #2, #3, #5, #6, #8, #9, #10)
re-read end-to-end. Two had live findings:

- ~~**PR #2 follow-up — thumbnail concurrency unbounded**~~ — fixed in
  `e6d7dd0` ("Fix PR #2 follow-up: bound thumbnail concurrency").
  `Documents.fetch_thumbnails_async/2` switched from raw `Task.start/1`
  to a single supervised parent task running `Task.async_stream/3`
  with `max_concurrency: 8` under `PhoenixKit.TaskSupervisor`. Opening
  a folder with hundreds of files no longer fans out hundreds of
  simultaneous Drive requests.
- ~~**PR #9 follow-up — silent `handle_info` catch-all + bare `apply` in
  `:perform_file_action`**~~ — fixed in `9c97300` ("Fix PR #9 follow-up:
  handle_info catch-all logging + backend try/rescue").
  `documents_live.ex` catch-all now logs at `:debug`; the
  `:perform_file_action` handler wraps the backend call in `try/rescue`
  so a Drive API exception keeps the LV alive and surfaces a translated
  failure flash instead of crashing.

The other six PRs (#1, #3, #5, #6, #8, #10) had no live findings;
stub FOLLOW_UPs were committed in `13361c7`.

Phase 2 — quality sweep. Commits:

- **`3686c51`** — C1 + C3 + C4: `PhoenixKitDocumentCreator.Errors`
  atom dispatcher (28 atoms with literal-gettext `message/1` clauses),
  `log_drive_error/2` 500-char body truncation in GoogleDocsClient and
  DriveWalker, AGENTS.md additive pass with the canonical "What This
  Module Does NOT Have" section pinning no-local-editor / no-local-PDF
  / no-Oban-scheduler / no-retry-layer / no-telemetry deliberate
  non-features (the Google Docs pivot makes a lot of old PR review
  findings N/A).
- **`7d5dfa7`** — C5: `phx-disable-with` on every async + destructive
  button (refresh, create, modal create, file actions in toolbar +
  trash row, export PDF, restore, delete).
- **`e72e686`** — C7: full LiveView test infrastructure (Test.Endpoint,
  Test.Router, Test.Layouts with flash-rendering divs, LiveCase, hooks,
  sandbox setup, ActivityLogAssertions helper, test-only Postgres
  migration that creates the module's tables + `phoenix_kit_activities`
  + `uuid_generate_v7()`).
- **`2c60f11`** — C8 + C9 + C10: per-atom Errors EXACT-string pin tests
  (every atom in `@type error_atom`), per-action activity-log tests for
  every CRUD mutation that's reachable without HTTP stubs, LiveView
  smoke tests for documents_live + create_document_modal.
- **`1157d33`** — C11 delta audit: pgcrypto extension added to
  `test_helper.exs` next to uuid-ossp (uuid_generate_v7's
  `gen_random_bytes` dependency was implicit — would break on a fresh
  `createdb`); modal phx-disable-with pin tests.
- **`15ac11a`** — C12 re-validation Round 1: `Task.start` →
  `Task.start_link` in 2 LV handlers (orphan task fix), @spec backfill
  on `Variable` + `Paths` + 5 most-called GoogleDocsClient functions.
- **`2bc8a57`** — final tidy: format + credo nested-alias fix.
- **`ff5666b`** — backfill `@spec` on remaining GoogleDocsClient
  public functions.
- **`8453ac5`** — document PDF download endpoint + inline-script Hook
  migration as TODOs in AGENTS.md.
- **`10cb595`** — C12.5 deep-dive: 7 in-scope fixes — SSRF guard on
  Drive-supplied thumbnail URLs (`validate_thumbnail_url/1` rejecting
  RFC1918 / loopback / link-local / `*.local` / non-http(s) schemes),
  audit-log gap on bulk register API, mount race fix
  (`subscribe → list_*_from_db` order), dead `extract_from_html/1`
  removal, commented-out `def` deletion, README missing Errors API
  section, sync error log lacks resource-uuid context.

**Final state of the original sweep**: 161 → 213 tests, 10/10 stable
runs, `mix precommit` 0 errors. Push permission noted: `gh repo view
--json parent` confirmed `BeamLabEU/phoenix_kit_document_creator`
parent fork relationship despite the local repo having no `upstream`
remote configured (this trap was added to the workspace AGENTS.md).

## Batch 2 — re-validation 2026-04-26

Phase 1 PR triage re-verified clean — all eight PRs' fix sites still
hold in current `lib/`. One stale FOLLOW_UP description in
`10-nested-subfolders-register-api/FOLLOW_UP.md` was corrected: the text
claimed an `:erlang :queue` ADT swap in commit `56d5c66`, but the
actual implementation uses level-batched chunking (also O(N) — same
end effect, different mechanism). Doc-only fix; no code change.

Phase 2 closed the C12 deltas the original sweep predates:

- ~~**Catch-all `handle_info` in `GoogleOAuthSettingsLive` was silent**~~
  — clause at `web/google_oauth_settings_live.ex:273` previously dropped
  unexpected messages with no trace. Promoted to `Logger.debug` matching
  the `documents_live.ex:224-226` precedent. Without this, stray PubSub
  broadcasts or test-fixture messages are impossible to debug.
- ~~**Error-path activity logging gap on 8 user-driven mutations**~~ —
  `create_template`, `create_document`, `delete_document`,
  `delete_template`, `restore_document`, `restore_template`,
  `export_pdf`, and `set_correct_location` all logged only on `:ok`.
  When Drive is down or folders are unreachable, the user-initiated
  click was erased from the activity feed. Added a private helper
  `log_failed_mutation/4` that lands a `db_pending: true` audit row
  on every error branch (matching the existing precedent at
  `documents.ex:615-621` for `create_document_from_template`). PII-safe
  metadata only (`google_doc_id`, `name`); the technical reason stays
  in the surrounding `Logger.error`.
- ~~**Stale `:queue` claim in PR #10 FOLLOW_UP**~~ — wording fix in
  `dev_docs/pull_requests/2026/10-nested-subfolders-register-api/FOLLOW_UP.md`.

### Tests added (Batch 2 — 2026-04-26)

- `test/integration/activity_logging_test.exs` — 8 new error-path
  pinning tests, one per mutation, exercising the deterministic
  `:not_configured` / `:*_folder_not_found` failure paths that fire in
  the test env without HTTP stubs. Each test asserts the row's
  `actor_uuid`, `db_pending: true` flag, `resource_type`, and that
  PII-leak fields like `size_bytes` are absent on the error path.
- `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs`
  (new file) — mount smoke test pinning the page header, plus a
  `handle_info` catch-all test using `capture_log` at `:debug` (with
  per-describe Logger level bump because `config/test.exs` defaults to
  `:warning`). Pins both the survival-after-stray-message behaviour and
  the actual log line.

### Skipped (with rationale)

- **Atom-bombing hardening at `google_oauth_settings_live.ex:226`** —
  the `String.to_existing_atom(field)` call is gated by
  `if field in @valid_path_fields` on the line immediately above. The
  agent flagged this as theoretical ("if a future refactor removes the
  guard"), not a live vulnerability. AGENTS.md:472 calls out this kind
  of hypothetical narrowing as an overstatement to verify before
  acting.
- **Broad `rescue _e ->` in `documents_live.ex:120-123` and `203-214`** —
  both are around external Drive/Docs API calls and have explicit
  comments justifying why catching everything is correct (sync mid-fail
  is safe, file-action crash would wedge `pending_files` on remount).
  AGENTS.md:472 lists this as a typical false positive — defensive
  rescues around external-API calls are acceptable when the comment
  documents the intent, which both already do.
- **Hardcoded `secret_key_base` in `config/test.exs:28`** — test-only
  config, not loaded in prod / dev. Acceptable for the same reason as
  every other phoenix_kit module's test config.
- **Status badge helper functions / Unicode + long-string edge tests**
  — Batch 3 fix-everything candidates. Surfaced for Max if a fix-
  everything pass is authorised; otherwise punted.
- **Req.Test stubs to enable Drive-bound LV mount tests** — feature
  work (test infra), not a pinning gap. The error-path coverage above
  already pins the `db_pending: true` audit-row behaviour. Happy-path
  per-action LV tests (`assert_activity_logged("template.created", ...)`)
  remain dependent on a `Req.Test`-via-app-config retrofit on
  `GoogleDocsClient`. Surfaced as Batch 3 candidate.

### Files touched (Batch 2)

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex` | `require Logger`; promoted catch-all to `Logger.debug` |
| `lib/phoenix_kit_document_creator/documents.ex` | `log_failed_mutation/4` helper + `:error`-branch logging on 8 mutations |
| `test/integration/activity_logging_test.exs` | +8 error-path tests |
| `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs` | new file: 2 tests (mount + handle_info catch-all) |
| `dev_docs/pull_requests/2026/10-nested-subfolders-register-api/FOLLOW_UP.md` | corrected stale `:queue` description |

### Verification (Batch 2)

- `mix compile --warnings-as-errors` — clean
- `mix test` — 213 → 223 tests (+10), 0 failures
- 10/10 stable runs (see Final checklist below)
- Pre-existing log noise (`Folder discovery failed: {:error, :not_configured}`)
  unchanged — Drive isn't configured in test env, expected

## Open

None. Items marked "skipped" above are documented with rationale; if
Max authorises a Batch 3 fix-everything pass, the candidates surface
as Req.Test stubs + status badge helpers + edge-case test coverage.
