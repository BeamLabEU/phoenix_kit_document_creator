# PR #11 Follow-Up — Round 3 (test pin + content-type log)

**Date**: 2026-04-30
**Reviewer**: Claude (Opus 4.7)
**Trigger**: User asked "anything we need to fix/improve here?" after
the round-2 commit landed.

Round 2 fixed the H1 SSRF redirect bypass and the H2 dead `rescue`
clause but landed without an end-to-end test for H1, and left the
L2 content-type silent downgrade unfixed. This round closes both,
plus updates CLAUDE_REVIEW.md to retract the L1 finding (initial
reading missed that `normalize_register_attrs/1` already calls
`validate_file_id/1`).

## Changes

### 1. End-to-end test for the SSRF redirect block

**File**: `test/google_docs_client_test.exs`

Added a `describe "fetch_thumbnail_image/1 (SSRF redirect block)"`
block with two tests:

- **Does not follow a 302 to an internal host.** Stubs Req via
  `Req.Test.stub/2` to return `302 Location: http://169.254.169.254/...`
  for an *allowed* input URL (`https://lh3.googleusercontent.com/abc`).
  Asserts `{:error, :thumbnail_fetch_failed}` and uses
  `assert_receive`/`refute_receive` on a `send(self(), {:plug_called,
  conn.host})` to pin that the plug was hit exactly once — Req did
  not chase the redirect.
- **Rejects an input URL outside the allowlist before issuing any
  request.** Sanity check that the URL guard fires first.

The test uses `Application.put_env(..., :req_options, plug: {Req.Test,
StubName})` with a unique stub atom per test (via
`System.unique_integer/1`) and `on_exit` cleanup. The test module is
switched from `async: true` to `async: false` because Application env
is global state — matches the existing pattern in
`test/integration/drive_walker_test.exs` and friends.

### 2. Expose `fetch_thumbnail_image/1` as `@doc false`-public

**File**: `lib/phoenix_kit_document_creator/google_docs_client.ex`

Same shape as `validate_thumbnail_url/1` directly above it. The
function is the SSRF perimeter: tests pin it without driving a full
Drive auth flow. Comment explains the public-but-not-API status.

### 3. Log content-type downgrade

**File**: `lib/phoenix_kit_document_creator/google_docs_client.ex`,
`extract_content_type/1`

Pre-fix, a Drive thumbnail with `Content-Type: image/svg+xml` (or
anything outside the `~w(image/png image/jpeg image/webp image/gif)`
allowlist) silently fell back to `image/png` in the data URI — no log,
hard to debug. Now `Logger.debug` records the original value.

## CLAUDE_REVIEW.md correction

L1 (`register_existing_document/2` doesn't validate `google_doc_id`)
was an incorrect finding. `normalize_register_attrs/1` at
`lib/phoenix_kit_document_creator/documents.ex:804` calls
`GoogleDocsClient.validate_file_id(a[:google_doc_id])` and returns
`{:error, :invalid_google_doc_id}` on a regex mismatch — the register
API is correctly guarded. The CLAUDE_REVIEW.md L1 entry is now struck
through with the correction.

## Verification

- `mix compile --warnings-as-errors`: clean.
- `mix test test/google_docs_client_test.exs`: **38 tests, 0 failures**
  (was 36; +2 redirect-block tests).
- Test output confirms both behaviour pins:
  - `[DocumentCreator] thumbnail fetch returned non-200 | status=302`
    — Req returned the 302 directly because `redirect: false`.
  - `[DocumentCreator] thumbnail URL rejected | reason=host_not_allowed
    | url="http://169.254.169.254/foo"` — URL guard fired before any
    request.

## Remaining items (still not fixed)

Per CLAUDE_REVIEW.md, these remain pre-existing and unaddressed:

- **M1** — DB queries in `mount/3` (changes SSR behaviour; warrants its
  own PR).
- **M2** — `Test.StubIntegrations` ETS table forces `async: false` if
  used concurrently from multiple tests.
- **S2** — `discover_folders/0` parallel tasks unsupervised.
- **S3** — `verify_known_file/2` is O(N) per event.
- **S5** — `actor_opts/1` duplicated across two LVs.

None block production; documented for future sweeps.
