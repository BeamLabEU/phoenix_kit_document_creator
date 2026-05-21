# Follow-up: post-merge fixes for PR #20 / #21

**Date**: 2026-05-21
**By**: @claude (Dmitri Don)

Applied directly to `main` after the review in [`CLAUDE_REVIEW.md`](./CLAUDE_REVIEW.md).
All non-integration tests pass (`343 tests, 0 failures`, integration excluded — no local
PostgreSQL); `mix format` clean; `mix credo --strict` down to the pre-existing baseline
(no new findings).

## 1. Stale `image_slots_for_template/1` test (review #1)

`test/integration/image_slots_test.exs` — replaced the exact-`==` assertion on the old
`%{name, kind}` shape with a `Map.take(.., [:name, :kind])` projection, plus an explicit
check that the `image_list` slot exposes `config["columns"] == 1`. The old assertion
would have failed under PostgreSQL once `:config` was added.

## 2. Drift-proof Phase-2 table identification (review #2)

`lib/phoenix_kit_document_creator/google_docs_client.ex`

- Added `match_new_tables/3`: reconstructs the pre/new table interleaving from the
  *doc2* (pre-Phase-1) indices and reads it off the post-Phase-1 tables **positionally**.
  Table order is never changed by inserts, so this is immune to the index drift that
  broke the old `startIndex` set-difference. Returns `:mismatch` (caller skips Phase 2)
  when counts don't line up.
- Rewrote `do_fill_table_cells` to use it; extracted the success branch into
  `fill_matched_tables/5` (also clears a Credo nesting finding).
- Tests: 5 new `match_new_tables/3` cases in `google_docs_client_table_test.exs`,
  including the previously-broken "pre-existing table **after** a placeholder" scenario
  and the "between two placeholders" case.

## 3. Move user-name resolution off the render path (review #3)

`lib/phoenix_kit_document_creator/web/documents_live.ex`

- Added `deleted_by_names` to mount assigns and `assign_deleted_by_names/1`, which
  resolves names from both trashed lists and is called only where those lists change
  (`:load_initial`, `:sync_from_drive` completion, `patch_file_in_assigns`).
- `assign_files/2` now reads `assigns.deleted_by_names` instead of querying per render.

## 4. Count queries for trash badges (review #4)

- `lib/phoenix_kit_document_creator/taxonomy.ex`: added `count_categories/1` and
  `count_types_for_category/2` (SQL `COUNT`, same `:status` semantics as the list fns).
- `web/categories_live.ex`: `reload_categories`/`reload_types` use the count helpers for
  the active-mode trash badge instead of `length(list_*(status: "deleted"))`.

## 5. Stamp/clear only the relevant schema (review #5)

`lib/phoenix_kit_document_creator/documents.ex`

- `stamp_deleted_data/3` and `clear_deleted_data/2` now take the schema. The schema is
  derived from `folder_key` (`deleted_schema/1`) on delete and from `type`
  (`restored_schema/1`) on restore, so only the table that owns the `google_doc_id` is
  updated instead of running an `update_all` against both.

## 6. EMU→PT test drift (review #6, pre-existing)

`test/.../google_docs_client/image_substitution_test.exs` — two `build_image_batch_requests/2`
single-image tests still asserted EMU object sizes; the code has emitted PT since
`fae10c8` (predates #20), so they were failing on `main`. Updated to PT (`px * 0.75`).

## Not done (out of scope / deferred)

- End-to-end test of the `substitute_all_images` Phase 1/2 orchestration (needs a
  stubbed Docs `get_document`).
- Pre-existing Credo complexity/nesting findings in `substitute_all_images`,
  `migrate_folders_to_root`, `rename_document`, and the OAuth/preset LiveViews — left at
  the repo's existing baseline.
- Empty trailing grid cells when `media` doesn't fill the last row (cosmetic).
