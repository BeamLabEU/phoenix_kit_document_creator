# PR #11 Follow-Up — Round 2 (post-merge review)

**Date**: 2026-04-29
**Reviewer**: Claude (Opus 4.7)
**Trigger**: Independent deep-dive review of merged PR #11
(`CLAUDE_REVIEW.md` in this folder).

PR #11 itself shipped cleanly. This round closes the two H-severity
items the deep-dive surfaced. Both are surgical fixes on top of the
landed code.

## H1 — SSRF guard does not block redirects

**File**: `lib/phoenix_kit_document_creator/google_docs_client.ex`
**Function**: `do_fetch_thumbnail_image/1`

### What was wrong

`Req.get(url, opts)` in Req `~> 0.5` follows redirects by default.
The SSRF allowlist `validate_thumbnail_url/1` checks the *input* URL
once, but a successful 302 from `lh4.googleusercontent.com` to
`http://169.254.169.254/...` was followed silently — the
metadata-service fetch then went out from the application server
with no second-pass guard.

The guard's threat model (compromised network path / tampered Drive
response) is exactly the case where redirects are the realistic
escalation path. The C12.5 deep-dive that introduced the host
allowlist explicitly cited metadata-service redirection as in-scope.

### Fix

```elixir
opts = [redirect: false] ++ Application.get_env(:phoenix_kit_document_creator, :req_options, [])
```

`redirect: false` is prepended so it wins via Keyword first-match
semantics — `:req_options` cannot override it. The thumbnail endpoint
never legitimately redirects, so closing it off is safe.

### Test status

The existing 8 SSRF guard tests pin `validate_thumbnail_url/1` (pure
function — no HTTP). Adding an end-to-end redirect-block test would
require wiring `Req.Test` into the test suite, which the PR
explicitly punted (the `req_options` config knob is the hook). Worth
landing alongside any future Req.Test plumbing for the
`fetch_thumbnail` LV path.

## H2 — Dead `rescue` clause in `discover_folders/0`

**File**: `lib/phoenix_kit_document_creator/google_docs_client.ex`
**Function**: `discover_folders/0`

### What was wrong

```elixir
try do
  Task.await_many(tasks, 30_000)
rescue
  e -> ...
end
```

`Task.await_many/2` on timeout sends `exit/1` through the link, not a
raised exception. `rescue` only handles `raise`d exceptions, so this
block was dead code: on a 30-second Drive folder hang, the LV
process exited and the supervisor restarted it — the `Logger.error`,
the `Task.shutdown(.., :brutal_kill)` cleanup, and the nil fallback
all never ran.

### Fix

```elixir
try do
  Task.await_many(tasks, 30_000)
catch
  :exit, reason ->
    Logger.error("Document Creator folder discovery failed: #{inspect(reason)}")
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    [nil, nil, nil, nil]
end
```

`catch :exit, reason` matches the actual signal type. `Enum.each` for
the cleanup (the previous code mixed `Task.shutdown` return values
with `nil` per-element via `Enum.map`). Returns a 4-element nil list
to match the destructure on the next line.

### Test status

No test for the timeout path — the original `rescue` clause had no
test coverage either (consistent with it being dead code). Pinning
this would require either an injectable timeout or a stubbed
`authenticated_request` that hangs — both reasonable but out of scope
for the round-2 fix.

## Verification

- `mix compile --warnings-as-errors`: clean.
- `mix test test/google_docs_client_test.exs`: 36 tests, 0 failures.
- Production diff: ~+12 lines, -8 lines, all in
  `lib/phoenix_kit_document_creator/google_docs_client.ex`.

## Pre-existing items surfaced (not fixed in round 2)

The deep-dive review (`CLAUDE_REVIEW.md`) documents several
pre-existing items that PR #11 didn't introduce and round 2 didn't
touch:

- **M1** — DB queries in `mount/3` of both top-level LiveViews (the
  `mount/3` is called twice on connected sessions).
- **M2** — `Test.StubIntegrations` ETS table forces `async: false` if
  used concurrently from multiple tests.
- **L1** — `register_existing_document/2` doesn't validate
  `google_doc_id` before upsert.
- **L2** — `extract_content_type` silent downgrade on type mismatch.
- **S2** — `discover_folders/0` parallel tasks are unsupervised.
- **S3** — `verify_known_file/2` is O(N) per event.
- **S5** — `actor_opts/1` duplicated across two LVs.

Each is in `CLAUDE_REVIEW.md` with severity, file/line, and proposed
fix. None block PR #11.
