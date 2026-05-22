# PR #23 Review — Documents card-grid density + form UI consistency

**PR:** [#23 — Documents card-grid density + form UI consistency](https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/23)
**Author:** @timujinne
**State:** MERGED (2026-05-22)
**Size:** +250 / −210 across 4 files
**Reviewer:** Claude (Opus 4.7) — Elixir/Phoenix skill loaded
**Review type:** post-merge

---

## 1. Summary

UI-consistency pass, no behavioural/logic changes:

- Documents/Templates list gets a denser, responsive card grid
  (`grid-cols-1 → 2xl:grid-cols-6`) via the core `card_grid_class` attr, plus a
  responsive toolbar (mobile action dropdown, collapsible filters).
- Category / Type / Preset form LiveViews swap hand-rolled
  `<input>`/`<label>`/manual error loops for the shared PhoenixKit core
  `<.input>` / `<.select>` / `<.textarea>` components.

## 2. Verdict

**Clean — no correctness bugs.** Verified against the *actual* dependency code
(not the PR description), since this repo has a history of fork code passing
core component attrs that don't exist in the released dep and silently no-op.

Verification performed:

- `mix compile --force --warnings-as-errors` passes. This is the real test —
  Phoenix emits a compile warning for any undeclared component attr, so a clean
  build confirms every attr resolves.
- The `card_grid_class` attr (and `wrapper_class`/`prompt`/`options` on
  `<.input>`, `options`/`prompt` on `<.select>`) all exist in the **released**
  dep, now `phoenix_kit 1.7.118` (mix.lock). The earlier "1.7.117 hardcodes the
  grid" warning comment was correctly removed.
- All three core components compose `class` **additively** onto their base
  classes, so `class="input-sm"` augments rather than replaces styling.
- Preset form param wiring is intact: form built `as: :preset`, handlers match
  `%{"preset" => params}`, so the field-derived names (`preset[name]`,
  `preset[scope_type]`) still line up after dropping the explicit `name=` attrs.
- The `<.select>` `field`-based selection is equivalent to the old explicit
  `selected={@preset.scope_type == type.uuid}` logic (`options_for_select`
  matches the form field value).
- `mount/3` lifecycle untouched; new `toggle_filters` handler is a pure assign
  flip. No DB queries moved into `mount`.

Bonus: error messages now route through `translate_error/1` (gettext) instead of
the old raw `{msg}` dump of `{msg, opts}` tuples.

---

## 3. Fixed in this follow-up

Both are safe consistency tweaks (compile-verified, no behaviour risk):

- **Skeleton grid spacing now matches the loaded grid.** The loading skeleton
  used `gap-4` while the real card grid uses `gap-3`, so card spacing visibly
  shifted at the loading→loaded transition. Skeleton changed to `gap-3`.
  (`documents_live.ex` loading-skeleton block.)
- **`card_grid_class` now carries an explicit base column count.** Added
  `grid-cols-1` so the value reads
  `gap-3 grid-cols-1 sm:grid-cols-2 …`, matching both the skeleton's ladder and
  the convention in the attr's own doc example. Zero behaviour change (CSS grid
  already defaults to one column) — purely explicitness/robustness.

---

## 4. Open items for the developer

Neither is a defect; both need a human judgement call, so they were *not*
changed.

### 4.1 Desktop toolbar reorders the status tabs (design sign-off)

On `lg+` the status-tabs + view-toggle block is `lg:order-last` and the filters
form is `lg:flex-1`, producing `[ filters … grow ][ tabs | view-toggle ]`.
Before this PR the status tabs sat on the **far left** of the toolbar; they now
render on the **right** on wide screens. The `lg:order-last` and the explanatory
comment make this look intentional, but it's a visible desktop layout change —
worth a quick design confirmation since the PR framing emphasises *mobile*
responsiveness.

- File: `lib/phoenix_kit_document_creator/web/documents_live.ex`, toolbar
  container (`flex flex-col … lg:flex-row lg:flex-wrap`) and the
  `lg:order-last` sub-div.

### 4.2 `wrapper_class` asymmetry between core form components (upstream)

`<.input>` accepts `wrapper_class` (used as `wrapper_class="mb-4"`), but
`<.select>` and `<.textarea>` do not — so those fields are spacing-wrapped in a
manual `<div class="mb-6">`/`<div class="mb-4">`. Works fine; just an
inconsistent idiom. If symmetry is wanted, the clean fix is an **upstream**
`phoenix_kit` change adding `wrapper_class` to
`PhoenixKitWeb.Components.Core.Select` and `.Textarea`, after which the manual
wrapper divs in the Type/Category/Preset forms can be removed.

---

## 5. Notes

- The `card_grid_class` string must remain a **literal** in this source file so
  the `phoenix_kit_css_sources` compiler exposes the Tailwind classes to the
  host app's CSS build. The PR (and the fix above) keep it literal — do not
  build this string dynamically.
- The `:requires_unreleased_core` test tag still in `test_helper.exs` is
  unrelated to this PR (it gates Integrations migration tests, not
  `card_grid_class`), so nothing went stale here.
