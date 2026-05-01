# PR #12 Follow-Up — fixes applied post-merge

PR #12 was reviewed in `CLAUDE_REVIEW.md`. The findings below were fixed
directly on `main` after merge to keep them moving without bouncing the work
back to the original author. Behavior changes (§1.2) and cross-version
coordination concerns (§1.3) were left alone — they deserve a fresh
discussion.

## Fixes applied

### §1.1 — Legacy plaintext OAuth secrets are wiped after migration **[security]**

`lib/phoenix_kit_document_creator.ex` — `do_migrate_oauth_credentials/1` now
calls a new `clear_legacy_oauth_key/0` helper after the activity log emission.
The legacy `document_creator_google_oauth` row is reset to `%{}` so
`client_secret` / `access_token` / `refresh_token` don't survive the move to
encrypted Integrations storage. Failure to clear is best-effort — logs a
warning, doesn't roll back the migration.

New test: `test/integration/active_integration_test.exs` →
`"credentials migration: clears the legacy oauth key after success"`. Tagged
`:requires_unreleased_core` like the other strict-UUID integration tests.

README + AGENTS.md updated to document the wipe as part of the migration
contract.

### §1.4 — `migrate_legacy/0` `with` block dropped

The `with creds_result <- ..., refs_result <- ...` chain produced no
short-circuit (no `else`, no `{:ok,_}` pattern) and just shadowed two plain
assignments. Replaced with sequential bindings. Both inner functions still
have their own `rescue`, the outer one still wraps the result, so behavior is
identical and the elixir-thinking "with-without-purpose" smell is gone.

### §1.5 — `uuid_shape?` regex / comment mismatch + duplication

The regex matches any RFC 4122-shaped UUID, not specifically v7. Two fixes:

1. Comment in `google_docs_client.ex` updated to say "RFC 4122-shaped UUID"
   and explicitly call out that the version digit isn't enforced (the guard
   only needs to discriminate "promoted" from "legacy `google` / `google:name`"
   inputs).
2. Duplicate regex in `phoenix_kit_document_creator.ex` removed. New
   `GoogleDocsClient.uuid?/1` is the shared helper; the boot-time sweep in
   `migrate_legacy_connection_references/0` now calls it instead of carrying
   its own copy of the regex.

### §1.6 — Misleading `uuid` variable name in `active_integration_uuid/0`

The pattern `%{"google_connection" => uuid}` matched any binary, including
legacy non-uuid strings. Renamed to `stored` so the `uuid?(stored)` check
reads as "is this stored value a uuid" rather than the tautological "is this
uuid a uuid".

### §1.8 — Hex-shape failing tests are now tagged

The three tests in `test/integration/active_integration_test.exs` that call
`PhoenixKit.Integrations.add_connection/3` directly (and the new §1.1 test
that exercises the migration path) are tagged `@tag :requires_unreleased_core`.

`test/test_helper.exs` excludes `:requires_unreleased_core` by default. To
opt in once core publishes the matching version:

```bash
mix test --include requires_unreleased_core
```

Standalone `mix test` against Hex `~> 1.7` now exits clean — no shape-mismatch
red herrings.

## Findings deferred / not addressed

| Finding | Reason |
|---------|--------|
| §1.2 — boot vs lazy fallback asymmetry for bare `"google"` | Behavior change. Worth a discussion: do we want lazy to *also* clear+log instead of silently picking the first connection, or do we want boot to mirror lazy's first-row pick? Either choice is defensible; pick one explicitly. |
| §1.3 — `already_migrated?/0` queries via legacy string key | Coupled to core's continued back-compat for `provider:name` lookup. Switch to `find_uuid_by_provider_name/1` once the floor `phoenix_kit` version is bumped past V107. |
| §1.7 — Lazy on-read writes mutate the DB during GET requests | Documented in code already; relevant only if reads ever go to a replica. No code change needed; just keep in mind. |
| §1.9 — Test stub uses `:named_table` ETS (implicit global) | Today's usage is `async: false` so the named-table coupling is invisible. Forward-looking only — re-key per-test if a second consumer joins. |

## Verification

- `mix compile` — clean (two pre-existing warnings about
  `migrate_legacy/0` callback and `find_uuid_by_provider_name/1` are
  Hex-shape drift unchanged from PR #12)
- `mix format --check-formatted` — clean
- `mix test` — 187 tests, 0 failures (207 excluded — adds one to
  PR #12's 206 because of the new §1.1 test)
