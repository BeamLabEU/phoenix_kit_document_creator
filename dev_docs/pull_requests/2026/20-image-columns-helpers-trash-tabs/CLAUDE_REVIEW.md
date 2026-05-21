# PR #20 + #21 Review: image columns, data persistence, trash metadata

**Author**: @timujinne
**Reviewer**: @claude (Dmitri Don)
**URLs**: https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/20,
https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/21
**Stats**: #20 +1155/−81 · #21 +1255/−93 (overlapping; #21 builds on #20)

This review covers both PRs together — #21 is stacked on #20 and the two were
merged minutes apart. Post-merge fixes from this review are tracked in
[`FOLLOW_UP.md`](./FOLLOW_UP.md).

## Strengths

- **Well-isolated pure helpers.** `content_width_pt/1`, `image_width_for_columns/2`,
  `table_image_inserts/3`, and `fill_table_cells/3` are pure and directly unit-tested,
  which is the right seam given the orchestration layer needs a live Docs API.
- **Backward-compatible API growth.** `build_image_batch_requests/2` delegates to a
  new `/3`; `image_slots_for_template/1`'s map grows a `:config` key that old
  pattern-matches still satisfy.
- **Iron Law respected.** Both LiveViews keep `mount/3` query-free; data loads in
  `handle_params`/`handle_info`.
- **Defensive jsonb.** Deletion metadata merges with `COALESCE(data,'{}') || …` and
  clears with `data - 'deleted'`, preserving sibling keys (tested).
- **Correct unit handling.** PT + float magnitudes, with a comment explaining why EMU
  and integer magnitudes are rejected by the API.
- **Good config hygiene.** `resolve_slot_config/3` stringifies the atom-keyed defaults
  before merging the jsonb-sourced config, avoiding mixed-key maps leaking to callers.

## Issues / Suggestions

Severity legend: 🔴 must-fix · 🟠 correctness risk · 🟡 efficiency · 🔵 minor.

### 🔴 1. Stale test: `image_slots_for_template/1` return shape (fixed)
`test/integration/image_slots_test.exs` asserted the old `%{name, kind}` shape via
exact `==`, but #21 added a `:config` key to every slot. The assertion fails under
PostgreSQL; it only "passed" locally because integration tests are auto-excluded with
no DB. Fixed in follow-up (assert name/kind projection + `config["columns"]`).

### 🟠 2. Phase-2 table identification drifts with pre-existing tables (fixed)
`do_fill_table_cells` identified the newly inserted tables by a `startIndex`
set-difference against a pre-Phase-1 snapshot. Phase 1's deletes/inserts shift the
absolute index of any content *after* a placeholder, so a pre-existing table located
after a multi-column slot gets a new `startIndex`, is misclassified as "new", trips the
count guard, and **all** Phase 2 fills are skipped — multi-column grids render as empty
tables (warning logged, no crash). Templates that use layout tables after an image
gallery hit this. Fixed in follow-up with order-based interleaving matching
(`match_new_tables/3`), which is drift-proof because Phase 1 never reorders tables.

### 🟡 3. User-name lookup ran in the render path (fixed)
`build_deleted_by_names/1` (→ `Auth.get_users_by_uuids/1`) was called from
`assign_files/2`, which runs inside `render/1` — so the trash view queried users on
every re-render. (`assign_files` already issued `list_categories` + an N+1
`list_types_for_category` per render, so this followed an existing anti-pattern.) Fixed
in follow-up: names resolve once when the trashed lists change and are read from assigns.

### 🟡 4. Trash badge counts loaded full rows (fixed)
`reload_categories`/`reload_types` did `length(list_*(status: "deleted"))` purely for a
badge number. Fixed in follow-up with `Taxonomy.count_categories/1` and
`count_types_for_category/2` (SQL `COUNT`).

### 🔵 5. Deletion stamp/clear hit both tables (fixed)
`stamp_deleted_data`/`clear_deleted_data` ran an `update_all` against *both* `Template`
and `Document` regardless of the operation; one always matched zero rows. Fixed in
follow-up by selecting the schema from `folder_key`/`type`. (Still not transactional
with the preceding Drive move — acceptable, low risk.)

### 🔵 6. Pre-existing: EMU→PT test drift (fixed, not from these PRs)
`google_docs_client/image_substitution_test.exs` still asserted EMU object sizes while
the code emits PT (since `fae10c8`, which predates #20). Two tests were failing on
`main` independently of these PRs; updated to PT as part of the cleanup.

### 🔵 7. Known limitations worth tracking
- Empty trailing cells when `media` doesn't fill the last grid row (cosmetic).
- `image_width_for_columns` can compute ≤0 width for an unrealistically narrow page at
  4 columns; not a concern at real page widths (~468pt).
- The orchestration (`substitute_all_images` Phase 1/2) has no end-to-end test;
  consider stubbing `get_document` to lock in the two-phase contract.

## Risk Assessment

**Low–medium.** Additive and gracefully degrading: the multi-column path falls back to
empty tables + a logged warning rather than corrupting documents, and inline rendering
is unchanged. The render-path query (#3) was a scaling smell, not a correctness bug. All
must-fix/correctness items are resolved in the follow-up.

## Recommendation

Approved with follow-ups applied (see `FOLLOW_UP.md`). The pure-helper decomposition is
a good foundation; the main remaining gap is end-to-end coverage of the Phase 1/2
orchestration.
