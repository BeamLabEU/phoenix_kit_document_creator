# PR #41 Review — Localize category and type names via the multilang data JSONB

**Author:** Timujeen (timujinne)
**Merged:** 2026-08-17 (`40dac61`)
**Reviewed:** 2026-08-17
**Verdict:** APPROVED — merged, with one missed display site fixed post-merge (see below)

---

## The change

Category/Type names were shown verbatim everywhere (filter dropdowns, the admin
taxonomy list, the category-select in the Type form) instead of resolving a
per-language override, unlike `PhoenixKitCatalogue.Catalogue` which already reads
translations through `Catalogue.get_translation/2`.

Adds `Taxonomy.localized_name/2`, mirroring
`PhoenixKitCatalogue.Catalogue.Translations.translated_name/2` on top of
`PhoenixKit.Utils.Multilang.get_language_data/2` against the existing (previously
unused) `data` JSONB column on both schemas — no migration needed. Applies it at
every display site in `taxonomy.ex`, `documents_live.ex`, and `categories_live.ex`,
and threads `locale` through `category_options/1` and `type_options/2`. Wires the
write side too: `CategoryFormLive` and `TypeFormLive` now use `MultilangForm`
(`mount_multilang`, `multilang_tabs`, `translatable_field`,
`merge_translatable_params`) so translations are actually enterable.

## Findings

### IMPROVEMENT - MEDIUM — `PresetFormLive` was outside the PR's sweep *(fixed post-merge)*

The PR's own commit message scopes the display-site sweep to `taxonomy.ex`,
`documents_live.ex`, and `categories_live.ex`. `preset_form_live.ex` — the
new/edit preset form reachable from `categories_live.ex`'s presets panel — was
not touched, and still read the raw `:name` field at two sites:

- The `"Category: <name>"` heading (`preset_form_live.ex:220`) showed the
  category's denormalized `name`, not the viewer's-locale translation.
- The "Document type" `<.select>` options (`preset_form_live.ex:243`) built
  `{&1.name, &1.uuid}` directly from `Taxonomy.list_types_for_category/1`,
  bypassing `localized_name/2` the same way `documents_live.ex`'s type dropdown
  did before this PR.

Since this is the same feature (translated category/type names in the admin UI)
and the same `Category`/`Type` structs used everywhere else in this PR, a
non-English admin editing a preset would see an untranslated category name and
untranslated type choices on the one form this sweep skipped.

**Fix applied:** `preset_form_live.ex` now reads `locale` the same way
`categories_live.ex` and `documents_live.ex` do — in `handle_params`/`load/5`
(after `mount/3`, so it runs after the host app's telemetry hook syncs the
process-global Gettext locale) — and both sites route through
`Taxonomy.localized_name/2`. Added
`PresetFormLiveTest` coverage locking in that both sites call `localized_name/2`
rather than reading `:name` directly (with the same "LiveView runs in its own
process" caveat the PR's own `CategoriesLiveTest` addition documents — the test
exercises the fallback path; the locale-switch behavior itself is already
covered by the `Taxonomy.localized_name/2` unit tests).

### NITPICK — `localized_name(record, nil)` doesn't always short-circuit to `record.name`

The moduledoc states: *"Returns `record.name` unchanged when `locale` is `nil` or
no translation data exists yet."* In the reference implementation
(`PhoenixKitCatalogue.Catalogue.Translations.translated_name/2`), a `nil` locale
short-circuits immediately: `translated_name(record, nil), do: Map.get(record, :name)`.

`Taxonomy.localized_name/2` instead does `Multilang.get_language_data(data, locale
|| "")`. When `data` already has multilang structure, `get_language_data` treats
`""` as a non-matching secondary language and returns `Map.merge(primary_data,
%{})` — i.e. the **primary-language JSONB override**, not the `name` column. In
current usage this is unobservable: the only writers of `data` are
`CategoryFormLive`/`TypeFormLive`, and both write the primary-language override
and the `:name` column together on every save (see `merge_translatable_params/4`
+ the plain `params["name"]` cast), so the two values are always identical in
practice. It would only diverge for a hypothetical future caller that updates
`:name` directly via `Taxonomy.update_category/3` without touching `:data` (the
tests do this, e.g. `taxonomy_test.exs:115`, but no production code path does).
Not fixed — documenting it here per the skill's "record why, don't over-engineer"
guidance rather than adding a guard for a case nothing currently triggers.

## Verification

- `mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, format check, `credo --strict`, dialyzer, `mix test
  --warnings-as-errors`) → exit 0, **863 tests, 0 failures, 1 skipped** (after the
  `preset_form_live.ex` fix + test; the merged PR alone was already green at 862).
- Manually traced the write path (`MultilangForm.merge_translatable_params/4` →
  `Multilang.put_language_data/3`) and the read path (`Multilang.get_language_data/2`)
  to confirm the `"_name"`/`"name"` key convention matches
  `PhoenixKitCatalogue.Catalogue.Translations` exactly.
- Confirmed the `locale` values threaded through (`Gettext.get_locale(PhoenixKitDocumentCreator.Gettext)`)
  are full BCP-47 codes (e.g. `"et-EE"`), matching the JSONB keys written by
  `PhoenixKit.Modules.Languages` — no short-code/full-code mismatch.
- Swept the rest of `lib/` for other un-migrated `Category`/`Type` `.name` reads
  (`preset_form_live.ex` was the only other display site; all others — variable
  names, breadcrumbs, template names — are unrelated schemas outside this
  feature's scope).
