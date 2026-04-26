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

### Dismissed (re-classified after second-pass review)

These items were initially flagged by C12 agents but, after verifying
against AGENTS.md:472 ("agents overstate; verify before acting") and
the surrounding code, are not real findings:

- **Atom-bombing hardening at `google_oauth_settings_live.ex:226`** —
  `String.to_existing_atom(field)` is gated by
  `if field in @valid_path_fields` on the line immediately above. The
  whitelist already mitigates the threat; the agent's concern was
  hypothetical ("if a future refactor removes the guard").
- **Broad `rescue _e ->` in `documents_live.ex:120-123` and `203-214`** —
  both wrap external Drive/Docs API calls and carry explicit comments
  justifying why catching everything is correct (sync mid-fail is
  safe, file-action crash would wedge `pending_files` on remount).
  AGENTS.md:472 lists this exact pattern as typical false-positive
  noise.
- **Hardcoded `secret_key_base` in `config/test.exs:28`** — test-only
  config, not loaded in prod / dev. Same shape as every other
  phoenix_kit module's test config.
- **`status_label/1` helper refactor** — current LV uses
  `gettext("lost")` / `gettext("unfiled")` on literal strings, status
  values are pinned by schema `validate_inclusion`. New statuses
  would require a migration anyway — this is a refactor without
  functional improvement.

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

## Batch 3 — fix-everything 2026-04-26

User pushed back on the initial Batch 2 "Skipped (with rationale)"
section, citing `feedback_followup_is_after_action.md`
("FOLLOW_UP.md is an after-action report, not a TODO parking lot —
we fix everything we find") and `feedback_review_verdicts.md`
("never silently classify as resolved"). Re-classified each item:
genuine dismissals moved to "Dismissed (re-classified after second-
pass review)" above; real findings closed in this batch.

### Real bug surfaced by edge-case testing

- ~~**`Document.creation_changeset/2` and both `sync_changeset/2` (Document + Template) missing `validate_length(:name, max: 255)`**~~
  — the full `Document.changeset/2` has it, but the upsert / register
  paths use `creation_changeset/2` and `sync_changeset/2` which
  skipped the validation. A 256-byte name therefore raised
  `Ecto.Adapters.SQL` exceptions instead of returning `{:error, %Ecto.Changeset{}}`.
  This is the canonical AGENTS.md "Coverage push pattern #1" trap —
  tightening the changeset contract converts raises to clean error
  tuples (a real behaviour improvement). Pinned by 5 new schema tests
  (`Document.sync_changeset/2` + `Document.creation_changeset/2` +
  `Template.sync_changeset/2` × {255-char boundary, 256-char rejection,
  Unicode round-trip}) plus the integration tests below.

### Edge-case tests added

- **`Variable` helpers** (`test/phoenix_kit_document_creator_test.exs`):
  6 new tests — duplicate dedup, malformed-placeholder rejection,
  Unicode (ASCII-only `\w` regex behaviour pinned), non-binary input,
  5K-char input, Unicode round-trip in `humanize/1`, empty list
  in `build_definitions/1`.
- **`register_existing_document/2`** (`test/integration/documents_test.exs`):
  6 new tests — Unicode name round-trip, 256-char name rejection (now
  a clean changeset error after the schema fix), 255-char boundary
  acceptance, SQL-metacharacter literal handling, empty-name
  normalize-step rejection (`{:error, :missing_name}` atom — pinned
  the actual return shape so a future refactor that pushes this into
  the changeset doesn't silently change the public API).
- **`CreateDocumentModal`** (`test/phoenix_kit_document_creator/web/components/create_document_modal_test.exs`):
  5 new tests — Unicode variable name rendering, multiline vs text
  type rendering, long template name surfaces in form value,
  `creating: true` disables the submit button, Cancel button does NOT
  carry `phx-disable-with` (UI-state-only — pinning the rule
  explicitly).

### Files touched (Batch 3)

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/schemas/document.ex` | added `validate_length(:name, min: 1, max: 255)` to `sync_changeset/2` and `creation_changeset/2` |
| `lib/phoenix_kit_document_creator/schemas/template.ex` | added `validate_length(:name, min: 1, max: 255)` to `sync_changeset/2` |
| `test/phoenix_kit_document_creator_test.exs` | +6 Variable edge-case tests |
| `test/integration/documents_test.exs` | +6 register edge-case tests |
| `test/schemas/document_test.exs` | +5 changeset length/Unicode tests |
| `test/schemas/template_test.exs` | +3 sync_changeset tests |
| `test/phoenix_kit_document_creator/web/components/create_document_modal_test.exs` | +5 modal validation tests |

### Verification (Batch 3)

- `mix compile --warnings-as-errors` — clean
- `mix test` — 223 → 247 tests (+24), 0 failures
- 5/5 stable runs at 247
- `mix format` + `mix credo --strict` + `mix dialyzer` — all clean

## Surfaced as a question (not deferred)

Per `feedback_followup_is_after_action.md` ("deferred items get
surfaced as questions, not parked in FOLLOW_UP"):

- **Req.Test stub retrofit + Drive-bound action LV mount tests** —
  enables happy-path coverage of the 11 drive-bound actions
  documented at `test/integration/activity_logging_test.exs:125-137`
  (`template.created` / `document.created` / `*.deleted` / `*.restored`
  / `*.exported_pdf` / `sync.completed` / etc.). Pattern is the AI
  module's Batch 4 (`e4519a8` + `5bbf273`) — `Application.get_env(:phoenix_kit_document_creator, :req_options, [])`
  threaded through `GoogleDocsClient.http_*` entry points so tests
  route HTTP through `Req.Test` plug stubs without external traffic.
  Production behaviour unchanged when the config is absent. Estimated
  ~60–90 min based on AI module precedent (which produced +299 tests
  and lifted coverage 36.96% → 90.93%). Open question for Max — this
  is a separate batch in scope, comparable to the AI module's Batch 4
  coverage push.

## Open

None — all real findings closed in Batches 2 + 3. Drive-bound
happy-path coverage waits on the question above.
