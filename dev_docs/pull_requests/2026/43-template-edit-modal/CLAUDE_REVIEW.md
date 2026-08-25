# Claude Review — PR #43

Reviewed the merge diff (`f94921b..3a276f5`, squashed into `0143527`) against
`lib/phoenix_kit_document_creator/web/documents_live.ex` and its test file,
following `elixir:phoenix-thinking` (LiveView mount/event conventions) and this
repo's `AGENTS.md`.

The PR's own commit history shows it already went through an internal review
round on the author's side — several commits are explicitly titled "(pi
review)" and fix a double-submit crash, an error-path draft loss, and a
missing membership-unchanged guard. Those fixes are present and covered by
tests in the merged diff. This pass looked for anything that round missed.

## Findings

No bugs found. Specifically checked and confirmed clean:

- **No DB queries in `mount/3`** — the Iron Law. Untouched by this PR; all new
  queries (`template_modal_taxonomy/0`, `current_membership_maps/1`) run from
  `handle_event`, not `mount`.
- **No stale references to the removed events/components.** Grepped for
  `set_template_language`, `toggle_template_category`, `set_template_group`,
  `render_language_picker`, `render_template_category_popover`, `lang-pop` —
  the only hit is an explanatory comment in the test file.
- **`enabled_languages` attr threading.** Moved from its own component into
  `render_category_picker`'s required attrs; both call sites (card layout,
  table layout) pass it. No missing-attr crash.
- **`short_month/1` dependency.** `format_datetime/1` now calls
  `PhoenixKit.Utils.Date.short_month/1` from core instead of
  `Calendar.strftime`'s English-only `%b`. Verified the function exists in the
  resolved `phoenix_kit` 2.13.9 (`deps/phoenix_kit/lib/phoenix_kit/utils/date.ex`)
  — no unreleased-core-attr drift.
- **Gettext completeness.** All 13 new/changed msgids are present and
  translated (not left as empty `msgstr`) in `en`, `et`, and `ru`.
- **Double-submit guard, error-path draft retention, unchanged-save skip** —
  all three "(pi review)" fixes from the PR's own history are correctly
  implemented and each has a dedicated test.

## Improvement (not fixed) — MEDIUM

**Save is two independent writes, not atomic.** `template_modal_save` runs
`maybe_apply_membership_write/4` then `maybe_apply_template_language_write/3`
via a `with`. If the membership write succeeds and the language write then
fails, the category/group changes are already persisted and broadcast, but the
modal stays open (by design, so the user can retry) showing a draft that now
*looks* unsaved for language only — there's no signal that part of the save
already landed. A retry re-runs the (now-unchanged) membership write too,
producing a harmless but wasted delete+reinsert (a new membership row UUID for
the same category/group pins, per the "unchanged Save" test's own assertion
technique).

Not fixed: wrapping both writes in one `Ecto.Multi` would fix the atomicity
but touches `Taxonomy.set_template_memberships/3` and
`Documents.update_template_language/3`'s transaction boundaries, which are
outside this PR's diff and reused elsewhere. Given the failure window requires
two independent write failures in sequence (a DB-level partial-failure edge
case) and the current behavior is safe (no crash, no lost draft, an idempotent
retry), this is a follow-up rather than a blocker.

## Gate

`mix precommit` (format, `credo --strict`, `dialyzer`, full test suite):
clean — 1166 mods/funs analyzed by credo with no issues, dialyzer passed
(pre-existing ignored warnings only, unrelated to this diff), 869 tests / 0
failures / 1 skipped (DB-gated integration test, expected in this sandbox per
project convention).

No code changes were made as part of this review — the PR was already correct
by the time it reached this pass.
