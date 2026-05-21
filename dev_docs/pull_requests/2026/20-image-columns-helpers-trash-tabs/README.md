# PR #20: feature/image-columns — data persistence, multi-column Google Docs helpers, unified Active/Trash tabs

**Author**: @timujinne
**Reviewer**: @claude (Dmitri Don)
**Status**: Merged
**Commit**: `c97a009` (merge); feature commits `5d13816..6944db2`
**Date**: 2026-05-21

## Goal

Bundle five commits accumulated on `feature/image-columns`. The headline is
multi-column image rendering in composed Google Docs: an `image_list` slot can
render its images as an N-column grid instead of a vertical stack. Supporting
changes persist the "recipe" that produced a composed document, surface who
trashed a file (and when), handle Drive 404s gracefully, and unify the
Categories Active/Trash sub-tabs with the Documents page.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `documents/composer.ex` | Writes a caller-supplied `:data` opt onto the composed `Document`. |
| `documents.ex` | `schema_to_file_map/1` exposes `data`; `stamp_deleted_data`/`clear_deleted_data` write/clear `data["deleted"]` (`at`, `by_uuid`) via jsonb `update_all` on trash/restore. |
| `google_docs_client.ex` | `content_width_pt/1`, `image_width_for_columns/2`; two-phase table flow (`table_image_inserts/3` + `fill_table_cells/3`); column-aware dispatch in `build_image_batch_requests/3`; Drive 404 → `:drive_file_not_found`. |
| `web/categories_live.ex` | Replaces boolean `*_trash` assigns with string `*_status_mode`; shared `status_subtabs/1` component matching `DocumentsLive`; trashed counts. |
| `web/documents_live.ex` | "Deleted" column/line in the trash view; resolves `by_uuid → display name`; warning banner for `:drive_file_not_found` on restore. |
| `errors.ex` | New `:drive_file_not_found` message. |

### Multi-column rendering (the core)

`image_list` slots carry a `columns` value (1–4). The renderer dispatches on it:

- **columns == 1** → inline `insertInlineImage` requests, width = full content width
  in PT.
- **columns >= 2** → a **two-phase** batch:
  - *Phase 1* deletes the placeholder and emits `insertTable` (rows = `ceil(n/cols)`).
  - *Phase 2* re-fetches the doc, locates the newly inserted tables, and emits one
    `insertInlineImage` per cell (last-first, to avoid index drift), width =
    `image_width_for_columns(content_width, cols)`.

Phase 2 needs to tell the *new* tables apart from any tables already in the
template — see the FOLLOW_UP for how that identification was hardened post-merge.

## Implementation Details

- **Units**: object sizes are emitted in `PT` (not `EMU` — Google's `Unit` enum
  rejects EMU). Magnitudes are coerced to float (`* 1.0`) because the API rejects
  integer magnitudes.
- **jsonb merge**: `data["deleted"]` is written with
  `COALESCE(data,'{}') || jsonb_build_object('deleted', …)` so other `data` keys
  survive; restore clears it with `data - 'deleted'`.
- **Iron Law**: `mount/3` does no DB work; data loads in `handle_params`/handlers.

## Testing

- [x] Unit tests added for width math, the table phase-A/B helpers, and the
      column-dispatch path (`google_docs_client_*_test.exs`).
- [x] DB-backed `data["deleted"]` stamp/clear and Drive-404 tests (integration,
      excluded when no PostgreSQL).
- [ ] Phase 1/2 orchestration (`substitute_all_images`) is not exercised
      end-to-end (needs a stubbed Docs `get_document`); the pure helpers it
      delegates to are covered.

## Related

- Follow-on PR: [#21](/dev_docs/pull_requests/2026/21-image-columns-config-sidebar/) — exposes `columns` in the template editor.
- Review: [`CLAUDE_REVIEW.md`](./CLAUDE_REVIEW.md) (covers #20 and #21)
- Post-merge fixes: [`FOLLOW_UP.md`](./FOLLOW_UP.md)
