# PR #10 Review: Nested subfolder support and consumer register API

**Author**: mdon (Max Don)
**URL**: https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/10
**Status**: Merged (commit `d78d8ad`)
**Stats**: +1149 / −188

## Overview

Two logically independent features, bundled because they remove the same "flat folder" assumption:

1. **`GoogleDocsClient.DriveWalker`** — new module that centralises paginated Drive listing (`pageSize: 1000` + `nextPageToken` looping) and provides a BFS `walk_tree/2` returning every descendant folder plus every Doc with its owning `folder_id` and resolved path. `list_folder_files/1` and `list_subfolders/1` on the parent client delegate here. Fixes silent data loss past 100 items in the previous implementation.
2. **`Documents.register_existing_{document,template}/2`** — DB-only upsert for consumers that do their own Drive-side copy/placement (e.g. `documents/order-N/sub-M/`). Paired with `create_document_from_template/3` now accepting `:parent_folder_id` / `:path` options, and a `MapSet`-based `classify_by_location/5` that treats any descendant of the managed root as `:published`.

Also: `foreign_key_constraint(:template_uuid)` on `Document`, `Documents.pubsub_topic/0` as single source of truth, catch-all `handle_info/2` in `GoogleOAuthSettingsLive`, and extensive AGENTS/README updates.

## Strengths

- **Correct preservation semantics on re-register.** `on_conflict: {:replace, [:name, :status, :path, :folder_id, :updated_at]}` intentionally omits `template_uuid` / `variable_values` / `thumbnail`; `maybe_put/3` avoids nil-clobbering optional fields. Covered by the "re-register without template_uuid/variable_values preserves existing values" test.
- **`classify_by_location/5` ordering is right.** Deleted → record's stored `folder_id` → allowed-folders MapSet → unfiled. A deliberate move into a managed subfolder stays `:published` after the walker runs.
- **`foreign_key_constraint(:template_uuid)`** surfaces a changeset error instead of a raw FK exception for bad template UUIDs.
- **Security guard**: `validate_file_id` check in `register_existing_document` blocks path-injection-style `google_doc_id` values before they hit a Drive URL. Covered by a test.
- **Pagination fix**: `pageSize: 1000` + `nextPageToken` is a real win over the old `pageSize: 100` no-pagination path.
- **Batched `in parents` queries** at 40 IDs/chunk materially reduce API calls on wide trees.
- **Test coverage** is strong for the register API and `classify_by_location/5` — ~10 cases each covering happy path, idempotency, preservation, validation failures, and pubsub toggles.

## Issues / Suggestions

### Correctness

1. **PR complexity claim is slightly off.** Description says "`O(folders) + O(ceil(folders/40))` Drive calls." In practice the original `bfs_folders/3` still called `list_folders/1` **once per folder**; only *file* listing was batched. _→ Fixed: folder discovery is now batched the same way (see Follow-ups #5 below); AGENTS.md updated to match reality._
2. **BFS queue is O(n²).** `q ++ [child]` inside a reduce is O(len(q)) per enqueue. Fine at typical sizes; painful at 10k+ folders. _→ Fixed (see Follow-ups below)._
3. **`rescue _ -> nil` in `default_managed/2`** is too broad. A future typo/`FunctionClauseError` in `managed_location/1` would be silently swallowed and return a nil default. _→ Narrowed (see Follow-ups below)._

### Coverage gaps

4. **No walker HTTP-stub test.** The BFS recursion, `max_depth` clamp, path joining, and batched `in parents` OR-query are untested beyond nil guards. An HTTP stub covering a 2-level tree would be high-value. _Still open._
5. **No test for `create_document_from_template/3`'s new `:parent_folder_id` / `:path` options.** _Still open._

### Style / minor

6. **`@doc false def classify_by_location/5`** is public-by-necessity for testing. The `@doc false` + comment is acceptable, but future refactors have to preserve this arity as de-facto public API.
7. **`refute_receive {:files_changed, _}, 50`** — 50 ms is tight. _→ Bumped to 200 ms (see Follow-ups #4)._
8. **`test_helper.exs` PubSub bootstrap** ignores all `start_link` errors other than `:already_started`. _→ Fixed: explicit `{:error, reason} -> raise` (see Follow-ups #3)._
9. **`join_path/2`** has a `nil` clause that's dead if callers only pass strings. _→ Removed (see Follow-ups #4)._

### Environment (discovered during review)

10. **`test_helper.exs` raises on missing `psql`.** `System.cmd("psql", ...)` raises `ErlangError :enoent` on images without the psql client binary rather than falling through to `:try_connect`. _→ Fixed: wrapped in `try/rescue ErlangError` (see Follow-ups #3)._

## Follow-ups Applied

Seven improvements landed on the current branch after review (pre-commit), in two logical groups.

### Group A — Quick wins

#### 1. Narrowed `default_managed/2` rescue
`lib/phoenix_kit_document_creator/documents.ex`

```elixir
# Before
rescue
  _ -> nil

# After
rescue
  _ in [ArgumentError, KeyError, MatchError, BadMapError] -> nil
  _ in [DBConnection.ConnectionError, Postgrex.Error] -> nil
```

Preserves the "Settings not ready → nil default" behaviour while letting `FunctionClauseError` / `RuntimeError` from future typos propagate.

#### 2. Swapped BFS list-queue for `:queue`
`lib/phoenix_kit_document_creator/google_docs_client/drive_walker.ex`

Replaced the `q ++ [child]`-inside-reduce pattern with `:queue.in/2` + `:queue.out/1`. O(1) amortized in/out instead of O(n²) over a full walk. (Subsequently superseded by the level-based BFS in #4 below, but the safer queue discipline carried through.)

#### 3. `test_helper.exs` hardening
`test/test_helper.exs`

- Wrapped `System.cmd("psql", ...)` in `try/rescue ErlangError` so the suite loads cleanly in sandboxes/CI images without the `psql` client binary. Previously the suite crashed on module load; now it falls through to the connect-attempt branch.
- Added an explicit `{:error, reason} -> raise` clause to the test PubSub supervisor bootstrap so real startup errors surface immediately instead of turning into confusing downstream failures.

#### 4. Minor cleanups

- `drive_walker.ex`: removed dead `join_path(nil, name)` clause — no caller passes nil.
- `documents_test.exs`: bumped `refute_receive {:files_changed, _}` timeout from 50 ms → 200 ms; cheap insurance against slow-CI false positives.

### Group B — Folder-discovery batching

#### 5. Level-based BFS with batched folder queries
`lib/phoenix_kit_document_creator/google_docs_client/drive_walker.ex`

The original walker issued one `list_folders/1` call per folder — `O(folders)` sequential Drive calls. Refactored to level-by-level BFS: at each level, collect all folder IDs, issue a single batched `mimeType = 'folder' and ('a' in parents or 'b' in parents …)` query chunked at 40 IDs per request, then resolve each returned folder's owning parent from its `parents` field by matching against the current level.

File listing was already batched this way. Result: both folder discovery and file discovery now cost `O(ceil(N / 40))` requests per level instead of `O(N)` sequential calls. Matches the perf claim in the PR description.

**Behaviour preservation:**
- Same return shape (`{:ok, %{folders: %{...}, files: [...]}}`).
- `max_depth` semantics preserved: deepest folders recorded at depth `max_depth`; their children are not enumerated.
- `list_folders/1` public API unchanged (still the non-recursive primitive used by `GoogleDocsClient.list_subfolders/1`).
- Multi-parent folders (shared/starred) resolved to the first parent in the current BFS level, same "owning parent" rule as file annotation.

#### 6. AGENTS.md complexity claim updated
`AGENTS.md`

First correction after review noted that folder enumeration was still `O(folders)`. After the batching refactor, AGENTS.md now states both folder and file discovery cost `O(ceil(N / 40))` per level — matching reality.

#### 7. Module docs refreshed
`drive_walker.ex` `@moduledoc` updated to describe batching for both folder discovery and file listing, and to explain the `parents`-field ownership resolution.

### Verification

- `mix compile` — clean.
- `mix format --check-formatted` — clean.
- `mix test test/google_docs_client_test.exs` — 29 tests, 0 failures. (Postgrex connection errors in output are pre-existing noise from pool retry workers against the absent test DB; not caused by these changes.)
- Full `mix test` runs in the review sandbox post-fix #3 (previously crashed at module load); all non-integration tests pass, 161 integration tests correctly excluded.

## Risk Assessment

**Low.** Features are additive. Main watch-items:

- **Deep trees**: the walker walks everything; paired with the known-but-deferred index TODO on `status` / `inserted_at`, consumers with thousands of docs in nested subfolders may see slow admin listings until the migration lands.
- **Consumer-supplied `folder_id` / `path` outside the managed tree**: by design, next sync reclassifies as `:unfiled` — intentional self-healing, but easy to misunderstand. AGENTS.md and the `register_existing_document/2` doc call it out explicitly.
- **`:queue` migration** is behaviour-preserving; no semantic change to walk order or results.

## Recommendation

Approve. The PR shipped merged; seven follow-up improvements above are ready to commit (suggest splitting into two commits: quick wins / hardening, then folder-discovery batching as its own change). Queued as deferred work: walker HTTP-stub tests, `create_document_from_template/3` options coverage, and the `status` / `inserted_at DESC` index migration in phoenix_kit core.

## Related

- Previous PR review: [#9](/dev_docs/pull_requests/2026/9-trash-tab-restore-pending-spinner/)
- Walker module: `lib/phoenix_kit_document_creator/google_docs_client/drive_walker.ex`
- Register API: `lib/phoenix_kit_document_creator/documents.ex` (`register_existing_document/2`, `register_existing_template/2`, `pubsub_topic/0`, `broadcast_files_changed/0`)
- Deferred core work: `status` + `inserted_at DESC` indexes on `phoenix_kit_doc_documents` / `phoenix_kit_doc_templates` (migration in phoenix_kit core)
