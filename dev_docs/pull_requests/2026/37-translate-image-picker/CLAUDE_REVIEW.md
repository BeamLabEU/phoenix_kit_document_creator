# PR #37 — Translate the image picker, which was hardcoded in Russian

**Reviewed:** 2026-08-13 · **Author:** @timujinne · **Verdict:** merged unchanged.

## Summary

`Web.Components.ImagePicker` never used Gettext — all seven visible strings were
Russian literals, so an Estonian or English user got Russian inside an otherwise
translated page. The component now `use`s the module's Gettext backend and routes
every string through it, and the documents view's already-wrapped
`Search by name…` msgid is finally in the catalogues.

No findings.

## Worth calling out

- **The file counter became a real `ngettext/3`.** The old string was
  `({@filtered_count} файл.)` — the trailing period is an abbreviation used
  specifically to dodge Russian's three-form plural. Replacing it with
  `ngettext/3` is the correct fix rather than translating the dodge, and the
  verification output shows all three Russian forms resolving
  (`1 файл` / `2 файла` / `5 файлов`) alongside Estonian's two.
- **`Search by name…` was already wrapped and still broken.**
  `documents_live.ex:1180` called `gettext("Search by name…")`, but the msgid had
  never been extracted, so every locale silently fell through to English. That is
  the failure mode where the code looks correct and only the catalogue is wrong —
  reusing the same msgid for the picker's placeholder is right, and it fixes the
  documents view as a side effect.
- The `et` and `ru` catalogues carry real translations, not empty msgstrs.

## Deliberately out of scope, and correctly so

`mix gettext.extract --merge` reports **18 further uncatalogued messages** on
this branch, and its fuzzy matcher mistranslates several badly: `Reset` →
`Eelseade` / `Пресет` ("preset"), `%{count} file` → `%{count} sektsioon` /
`раздел` ("section"). Merging that batch here would have shipped confidently
wrong Estonian and Russian behind a seven-string fix. It needs its own pass with
the fuzzy flags reviewed one by one — the same conclusion `phoenix_kit_billing`
#20 reached about its own 71-message backlog on the same day.
