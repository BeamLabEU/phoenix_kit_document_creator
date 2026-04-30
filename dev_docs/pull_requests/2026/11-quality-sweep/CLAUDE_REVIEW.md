# PR #11 Review: Quality sweep + re-validation (errors, activity, async UX, SSRF, 77.92% coverage)

**Author**: mdon (Max Don)
**URL**: https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/11
**Status**: Merged (commit `4d3633b`)
**Stats**: +4957 / −109, 52 files
**Reviewed**: 2026-04-29

## Overview

A module-wide quality sweep on top of `BeamLabEU:main`, structured as
one canonical Phase 1+2 batch (2026-04-25) followed by four
re-validation batches (2026-04-26) against the post-Apr workspace
AGENTS.md pipeline. Not a feature PR — refactors existing paths only.

Major axes:

1. **Error contract**: new `PhoenixKitDocumentCreator.Errors` atom
   dispatcher (28 atoms with literal-`gettext/1` clauses); raw
   `{:error, "Foo failed: ..."}` strings replaced with tagged atoms
   across `GoogleDocsClient` + `DriveWalker`; truncated Drive-error
   logging.
2. **Activity logging**: every user-driven mutation now logs on the
   error branch with `db_pending: true` (8 sites), so a Drive outage
   doesn't erase admin clicks from the audit feed. Also subscribes to
   `document_creator:files` BEFORE the initial DB read.
3. **Async UX**: `phx-disable-with` on every async + destructive
   button; `Task.start` → `Task.start_link` (orphan-task fix);
   thumbnail concurrency capped at 8 via `Task.async_stream/3` under
   `PhoenixKit.TaskSupervisor`; `try/rescue` around the
   `:perform_file_action` backend call so a Drive raise doesn't wedge
   `pending_files`.
4. **Security**: SSRF guard `validate_thumbnail_url/1` on the
   Drive-supplied `thumbnailLink` URL — allowlist
   `*.googleusercontent.com` / `*.google.com`; rejects metadata
   service, loopback, RFC1918, look-alike hosts, non-http(s) schemes.
5. **Tests**: 161 → 374 tests; production coverage from ~52% →
   **77.92%** via built-in `mix test --cover` only — no Mox / no
   excoveralls. New `Test.StubIntegrations` ETS-backed integrations
   stub + full LiveView test rig (TestEndpoint / Router / Layouts /
   LiveCase / hooks / ActivityLogAssertions).
6. **Schemas**: `validate_length(:name, max: 255)` added to
   `Document.creation_changeset/2`, `Document.sync_changeset/2`,
   `Template.sync_changeset/2` — closes a real raise-vs-changeset
   asymmetry surfaced by edge-case tests.
7. **Docs**: `AGENTS.md` "What This Module Does NOT Have (by design)"
   section, README `Errors` section, FOLLOW_UP audit per prior PR.

`mix precommit` clean. 10/10 stable runs.

## Strengths

- **`Errors` module shape is right.** One literal `gettext/1` clause
  per atom (so `mix gettext.extract` picks them up), `message/1`
  catch-all that handles `{:error, atom}`, `Ecto.Changeset`, binary
  passthrough, and unknown terms via `inspect/1`. Per-atom EXACT-string
  pinning in `errors_test.exs` correctly avoids the `is_binary(msg)`
  smell — a future reword breaks the test, which is the point.
- **Activity log error-path coverage is complete.** The
  `log_failed_mutation/4` helper at `documents.ex:71-79` is symmetric
  with the success-path `log_activity` calls, and the `db_pending:
  true` flag is the right shape for "user clicked, system didn't
  finish". `persist_created_document/6` even keeps logging on DB-write
  failure with a stable activity row (`document.created_from_template`)
  rather than letting a sync re-emit it under `mode: "auto"` later.
  This is exactly the right resilience pattern for an audit feed.
- **Thumbnail concurrency cap is correct.** The fan-out at
  `documents.ex:1330` is one supervised parent under
  `PhoenixKit.TaskSupervisor` with `max_concurrency: 8`,
  `on_timeout: :kill_task`, `restart: :temporary`. Pre-fix opening a
  500-file folder fired 500 unsupervised `Task.start/1`s. The `send/2`
  to the LV pid no-ops if the LV closed mid-fetch, and the `:temporary`
  restart means the supervisor won't loop on a permanent fault. Good
  shape.
- **Mount race comment is honest.** The header comment at
  `documents_live.ex:25-32` correctly explains the
  subscribe-before-read ordering: at most one duplicate sync in the
  rare race window, gated by `within_cooldown?/1`. Sound reasoning.
- **`try/rescue` around `:perform_file_action` is correctly bounded.**
  The handler at `documents_live.ex:185-218` always cleans up
  `pending_files`, regardless of whether the backend returns
  `{:error, _}` or raises. Pre-fix a Drive raise wedged the spinner
  forever; now it surfaces a translated failure flash.
- **`integrations_backend/0` resolver is the minimum-viable injection
  point.** Three call sites dispatch through it; production reads the
  default; tests opt in via `Application.put_env`. ~+8 lines of
  production diff to make `Test.StubIntegrations` feasible without an
  external mocking lib. This is the right tradeoff — not Mox, not a
  behaviour wrapper, just a one-arity resolver.
- **Coverage push pattern is principled.** `test_coverage:
  [ignore_modules: [...]]` excludes test-support modules from the
  percentage so 77.92% reflects production code, not test infra. New
  HTTP-stub tests in `google_docs_client_http_test.exs` exercise every
  public client function on the 200 / non-2xx / transport-error axes.
- **Schema `validate_length` fix is a real bug.** The
  `creation_changeset` / `sync_changeset` family was missing the
  `validate_length(:name, max: 255)` that the full `changeset/2` had —
  256-byte names raised `Ecto.Adapters.SQL` exceptions instead of
  returning `{:error, %Ecto.Changeset{}}`. Tightening the changeset
  contract converts a raise to a clean error tuple. Pinned by 5 schema
  tests + 6 integration tests.
- **SSRF guard tests cover the canonical bypass attempts.** Metadata
  service, loopback, RFC1918, look-alike-suffix
  (`my-googleusercontent.com`), non-http(s) schemes, malformed input.
  `validate_thumbnail_url/1` is `@doc false`-public so tests can pin
  the host check without driving full `Req.get/2`.
- **`Test.StubIntegrations` ETS table is correctly `:public`.** Public
  + named so the LV process can read state set by the test process —
  the comment at `stub_integrations.ex:114-116` calls this out
  explicitly. The `{:error, {:unstubbed_request, method, url}}`
  fallback fails loud, which is what you want from a stub.

## Issues

### Correctness — Security

#### H1. SSRF guard does not block redirects.

**File**: `lib/phoenix_kit_document_creator/google_docs_client.ex:660-685`

`Req.get(url, opts)` follows redirects by default in Req `~> 0.5`
(verified locally: `req 0.5.17`). The SSRF guard `validate_thumbnail_url/1`
is checked once on the input URL. Once that URL passes, a
`https://lh4.googleusercontent.com/...` response carrying a
`Location: http://169.254.169.254/...` header is followed silently —
the metadata-service fetch is then issued from the application server
with no second-pass guard.

The realistic threat model is narrow (a compromised network path
between the app and `googleusercontent.com`, or a Drive-API response
that's been tampered with), but the C12.5 deep-dive that introduced
the guard explicitly flagged metadata-service redirection as in-scope.
The fix is one line.

```elixir
# google_docs_client.ex:668
case Req.get(url, [redirect: false] ++ opts) do
```

Putting `redirect: false` first lets a test override it via
`req_options` if needed (Keyword.merge/get-last semantics). Pin with a
test using `Plug.Conn.put_resp_header/3` + `send_resp(302, "")` via
`Req.Test`.

**Severity**: High (security). Easily fixed.

### Correctness — Concurrency

#### H2. Dead `rescue` clause in `discover_folders/0`.

**File**: `lib/phoenix_kit_document_creator/google_docs_client.ex:247-258`

```elixir
results =
  try do
    Task.await_many(tasks, 30_000)
  rescue
    e ->
      Logger.error("Document Creator folder discovery timed out: #{Exception.message(e)}")
      Enum.map(tasks, fn task ->
        Task.shutdown(task, :brutal_kill)
        nil
      end)
  end
```

`Task.await_many/2` does not raise an exception on timeout — it sends
an `exit/1` signal that propagates through the linked process. `rescue`
only catches `raise`d exceptions, not exits. This block looks defensive
but never fires; on a 30s Drive-folder hang the calling LiveView crashes
and the supervisor restarts it. The fallback `nil` map and the
`Task.shutdown/2` cleanup never run.

The fix:

```elixir
try do
  Task.await_many(tasks, 30_000)
catch
  :exit, reason ->
    Logger.error("Document Creator folder discovery timed out: #{inspect(reason)}")
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    [nil, nil, nil, nil]
end
```

Use `catch :exit, _` (not `rescue`); also note that `Task.shutdown/2`
returns `{:ok, _}` / `nil` per task, so `Enum.map` returning
`task_results` plus `nil` mixed isn't right — return a fixed
4-element nil list to match the destructure on the next line.

**Severity**: High (silent fallthrough on a timeout path). Easily fixed.

### Correctness — Phoenix paradigm

#### M1. Database queries in `mount/3`.

**File**: `lib/phoenix_kit_document_creator/web/documents_live.ex:24-70`,
`lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex:22-67`

Both top-level LiveViews execute database / settings reads in
`mount/3`. `documents_live.ex:38` calls `load_initial_state/1` which
hits `list_*_from_db/0` four times plus `load_cached_thumbnails/1`;
`google_oauth_settings_live.ex:23-41` calls
`GoogleDocsClient.get_folder_config/0`,
`GoogleDocsClient.active_provider_key/0`,
`Integrations.connected?/1`, `Integrations.list_connections/1`, and
`Integrations.get_integration/1`.

`mount/3` is called twice for connected sessions: once on the initial
HTTP request (disconnected), once on the WebSocket connection. Every
DB read in `mount/3` runs twice — visible in `EXPLAIN ANALYZE` traces
as duplicate-issued queries on every page load.

The Phoenix-paradigm fix is to assign empty/loading placeholders in
`mount/3` and load data in `handle_params/3`. `documents_live.ex` would
need an empty-state branch to avoid a flash-of-empty-list during the
WS upgrade, which is non-trivial because the not-connected banner
(`@google_connected == false`) is path-dependent.

This is a pre-existing pattern — PR #11 didn't introduce it. The
mount-race fix in commit `10cb595` reordered the *subscribe* call
relative to the read, which is a correct improvement, but it left the
2x-read fact untouched. Worth a follow-up sweep, not a PR-#11 blocker.

**Severity**: Medium (perf, not correctness). Pre-existing.

#### M2. `Test.StubIntegrations` ETS table forces `async: false`.

**File**: `test/support/stub_integrations.ex:25,117-122`

The named ETS table `:pkdc_stub_integrations` is process-shared global
state. Two async tests that both call `connected!/1` race the last
writer. The current test files using the stub don't all declare
`async: false`; if a future test does and another concurrent test calls
`stub_request/3`, results can interleave.

A safer shape: drop `:named_table`, keep the `tid` in the test pid's
process dict (or pass it explicitly). Or document `async: false` as a
hard requirement of using the stub.

Quick mitigation: a `@moduledoc` line saying "Tests using this stub
must be `async: false`" plus a runtime check.

**Severity**: Medium (test flake risk; not currently triggering).

### Correctness — Minor

#### ~~L1. `register_existing_document/2` doesn't validate `google_doc_id`.~~ — INVALID

Initial reading missed that `normalize_register_attrs/1` at
`documents.ex:804` already calls `GoogleDocsClient.validate_file_id/1`
and returns `{:error, :invalid_google_doc_id}` on failure. The
register API is correctly guarded. No fix needed.

#### L2. `extract_content_type` allowlist silently downgrades on mismatch.

**File**: `lib/phoenix_kit_document_creator/google_docs_client.ex:727-737`

A Drive thumbnail with `Content-Type: image/svg+xml` falls back to
`image/png` in the data URI. SVG-via-`<img>` doesn't execute scripts so
this is fine in practice, but the silent downgrade is surprising — a
caller debugging a "thumbnail looks wrong" issue won't see anything in
logs. Adding `Logger.debug("[DocumentCreator] thumbnail content-type
downgraded | original=#{v} → image/png")` would make this observable.

**Severity**: Low (debuggability). Fixed in round 3 (commit follows).

### Style / minor

#### S1. `do_fetch_thumbnail_image/1` — `Req.Response` body for binary downloads.

**File**: `google_docs_client.ex:668-672`

`Req.get(url, opts)` returns `body` decoded by Req's response steps —
PNG bytes pass through as raw binary, but a server sending
`Content-Encoding: gzip` will be auto-decompressed by Req. That's the
right behaviour for our use case but worth a comment so future
readers don't add `compressed: false` thinking they're tightening
something.

#### S2. `discover_folders/0` parallel fan-out uses unsupervised `Task.async`.

**File**: `google_docs_client.ex:240-258`

Four parallel `Task.async/1` calls inside a function not running under
`Task.Supervisor`. If `Task.await_many/2` is fixed (H2 above) and the
caller LV closes mid-await, the tasks won't be cleaned up — `Task.shutdown`
is only reached on timeout, not on caller-process exit. Linked tasks
would die with the LV automatically; consider switching to
`Task.Supervisor.async_stream_nolink/4` or just `Task.async_stream/3`
of a list.

#### S3. `verify_known_file/2` is O(N) per-event.

**File**: `documents_live.ex:1220-1228`

Four `Enum.any?/2` over the four file lists per event. Fine at typical
sizes (~hundreds of files), but if a folder ever has thousands the
modal-open and per-action latency adds up. A `MapSet` of known IDs
maintained on assign updates would be O(1). Not urgent.

#### S4. The inline `<script>` in `documents_live.ex:874-909` is still inline.

`AGENTS.md` already tracks "migrate inline-script to Phoenix Hook" as a
TODO, and PR #11 explicitly didn't tackle it (commit `8453ac5`). Fine.
The `window.__pkDocCreatorInitialized` guard correctly prevents double
event-listener attach on re-mount, so it's not actively buggy — just a
known follow-up. Worth noting that the script is rendered inside
`render/1` and pushed through every diff; moving to a hook removes
that re-emission cost too.

#### S5. `actor_opts/1` defined twice.

**Files**: `documents_live.ex:1213-1218`, `google_oauth_settings_live.ex:482-487`

Same shape, different names (`actor_opts/1` vs `actor_uuid/1`). Not a
bug; if a third LV is ever added, lift to a shared `Web.Helpers`
module.

#### S6. `Documents.fetch_thumbnails_async/2` orphans on LV close.

**File**: `documents.ex:1330-1348`

`Task.Supervisor.start_child/3` with `restart: :temporary` is
deliberately unlinked from the caller LV so in-flight thumbnail
persists complete after the user closes the tab. That is the documented
intent and the right tradeoff. Worth being aware: an admin who
flips between two big folders quickly stacks up to 8 + 8 + 8 …
concurrent thumbnail fetches as a queue, all consuming Drive API
quota. A `Process.monitor/1` of the LV with cancel-on-:DOWN would
mitigate, but is meaningfully more complex than what's here. Fine as-is
for the expected admin scale.

### Coverage gaps

- **No redirect-blocking test** for the SSRF guard (issue H1 above) —
  the existing tests only cover URL-shape rejection, not response-time
  redirect rejection. A `Req.Test` plug returning `302` to
  `169.254.169.254` would pin H1's fix.
- **No test for `discover_folders/0` timeout path** (issue H2 above).
- **The "78% production coverage" headline includes some HEEx render
  branches that are technically reachable but practically untested.**
  `documents_live_test.exs` exercises `handle_event`/`handle_info`
  exhaustively, but the conditional render branches under `@loading`
  ↔ `@view_mode` ↔ `@status_mode` cross-product are only
  string-asserted on the dominant path. Not worth chasing for the sake
  of the metric — the residual gap is acknowledged in the PR
  description.

## Per-batch sanity

- **Batch 2** (error-path activity logging on 8 sites + handle_info
  catch-all): correct shape; the helper consolidation is good.
- **Batch 3** (validate_length on schemas + edge tests): the schema fix
  is a real bug fix (raises → clean error tuple), not just test
  scaffolding.
- **Batch 4** (Req.Test stub retrofit): the production diff is
  minimum-viable. The ETS-backed stub is a reasonable tradeoff vs.
  pulling in Mox.
- **Batch 5** (coverage push 47.67% → 77.92%): the `test_coverage
  ignore_modules` config is the right way to report production-only
  coverage. The `PhoenixKit.TaskSupervisor` boot in `test_helper.exs`
  is necessary for the async-task LV paths to succeed in test env.

## Verification

- `mix precommit` clean (per PR description; not re-run for this review).
- The two H-severity items above are both reachable from current
  callers; fixes are surgical.
- Test count and coverage numbers in the PR description match what the
  diff produces.

## Conclusion

Solid quality sweep. The error-atom dispatcher, error-path activity
logging, async-UX hardening, and SSRF allowlist are all the right
shape. The C12 / C12.5 / batch-3 escalations from "skipped with
rationale" → "fixed everything" reflect the workspace
`feedback_followup_is_after_action.md` policy correctly.

Two real items to follow up:

1. **H1 — SSRF redirect bypass** (`Req.get` follows by default; one-line fix).
2. **H2 — dead `rescue` clause** in `discover_folders/0` (rescue→catch).

Both are landed in a follow-up commit on top of this PR (see
`FOLLOW_UP.md` Round 2).
