# PR #43: Replace the template category dropdown/language popover with an edit modal

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `f94921b..3a276f5` (merged at `0143527`)
**Date**: 2026-08-25

## Goal

Templates could belong to several taxonomy categories at once (each with its own
group), plus carry a language. Editing that lived in two separate per-row
popovers: a checkbox dropdown for categories/groups, and a native `popover` for
language. Both wrote to the DB on every single click/change. The dropdown
popover also lost DOM focus (and closed) on every `phx-change` patch, making
multi-category edits impractical. This PR replaces both with a single "Edit
template" modal: categories, groups, and language are edited together as draft
state and written once on Save.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/web/documents_live.ex` | New template-edit-modal assigns/events (`open_template_modal`, `template_modal_*`); removed `set_template_language`, `toggle_template_category`, `set_template_group` and their render functions (`render_language_picker`, `render_template_category_popover`); row/card now shows a compact read-only category+language summary with an "Edit" button; `format_time` now formats via `PhoenixKit.Utils.Date.short_month/1` for locale-correct month names instead of `Calendar.strftime`'s English-only `%b`. |
| `test/.../documents_live_test.exs` | Retargeted language/category tests at the modal flow; added modal-specific coverage (draft-not-written-until-save, Cancel discards draft, double-submit no-op, unchanged-Save skips the write). |
| `priv/gettext/{en,et,ru}/LC_MESSAGES/default.po` | New/changed msgids for the modal UI, translated in all three locales. |

## Implementation Details

- **Draft-then-commit.** `template_modal_categories`/`template_modal_language`
  are draft assigns, seeded from the DB on `open_template_modal` and discarded
  on `template_modal_close`. Only `template_modal_save` writes — membership
  replace-all (`Taxonomy.set_template_memberships/3`) and the language field
  are two independent writes, each skipped if the draft is unchanged from what
  was loaded (`maybe_apply_membership_write/4`, `maybe_apply_template_language_write/3`).
- **Double-submit guard.** A `handle_event("template_modal_save", _, %{assigns:
  %{template_modal_file: nil}})` clause makes a repeat Save (e.g. a fast
  double-click landing as two separate events) a no-op instead of crashing on
  `Taxonomy.set_template_memberships(nil, ...)`.
- **Error path keeps the draft.** A failed write no longer closes the modal —
  it stays open with the draft intact so Save can be retried, instead of the
  previous popover behavior of always discarding on error.
- **Taxonomy options cached on open.** `template_modal_taxonomy/0` (categories
  + per-category types) is called once in `open_template_modal`, not from
  inside the HEEx block, avoiding an N+1 requery on every `phx-change` while
  the modal is open.

## Testing

- [x] Unit tests added/updated (modal open/toggle/group/language/save/cancel,
      double-submit, unchanged-save-skips-write)
- [x] `mix precommit` — format, credo --strict, dialyzer, full test suite
- [ ] Manual UI verification (not performed in this pass — no running app/browser)

## Review

See `CLAUDE_REVIEW.md`.
