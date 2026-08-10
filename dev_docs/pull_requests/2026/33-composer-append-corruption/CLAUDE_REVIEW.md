# PR #33 — Fix composer append corruption, orphaned-row delete, taxonomy UX

**Reviewed:** 2026-08-10 · **Author:** timujinne · **Verdict:** merged, no
changes required. Released in **0.5.0**.

+4762 / −69 across 13 files, of which ~3300 lines are new tests. Reviewed as
part of the phoenix_kit 2.0 sweep.

## Why this got through with a light touch

Every finding in this PR is a *silent wrongness* bug — the composed document
came out incorrect with no error, no log, and a success return. That class does
not surface in a test suite that mocks the API from the same misunderstanding
the production code has, which is exactly what happened here and is the single
most valuable thing the PR fixes.

The findings, in rough order of subtlety:

- **`el["table"]["startIndex"]` does not exist in the real API** — `startIndex`
  belongs to the surrounding `StructuralElement`. So every pre-existing table
  reported `nil`, and because **Erlang term ordering sorts `nil` (an atom) after
  every integer**, sorting positions silently placed those tables last. Once
  more than one table-bearing section was appended, a later section's cell text
  landed in an earlier section's table. Fixed at all four call sites. Critically,
  the existing mocks had encoded the *wrong* shape and were corrected — without
  that, the fix would have failed the suite that was supposedly covering it.
- **`batch_update/2` never checked HTTP status.** It was the only client
  function that didn't, so a 400 returned `{:ok, resp}` and every caller
  reported success on an unmodified document. Combined with `batchUpdate` being
  atomic and rejecting empty-text `insertText`, one blank variable voided every
  substitution in a composed document, silently. The status check now also
  covers `append_template` and `substitute_images`, which share the helper.
- **`append_template/2` flattened via `get_document_text/1`, which walks only
  paragraph blocks** — so tables, and any `{{var}}` living only inside a table
  cell, were silently discarded.
- **`insertPageBreak` inserts an inline element, not a paragraph break**, so an
  appended section's first paragraph structurally merged with the target's last
  one, and paragraph-targeting requests reformatted the *preceding* section's
  tail. Confirmed live by the author (a centered appended heading centering the
  previous section's last sentence).

The style-replay work carries an explicit anti-inheritance guarantee — every
field is stated, including `bold: false` — so a fresh insert cannot inherit a
neighbour's formatting. That is the right shape for this problem.

## Verification

| Check | Result |
|---|---|
| `mix precommit` | **passes** against core 2.0.0 |
| `mix test` | **434 tests, 0 failures** (383 excluded — DB-backed and live-API sets; no Postgres available here) |
| Author's run | 800 tests, 0 failures against a real test DB; composer chain verified end-to-end against the live Docs/Drive API with the 9-section production dataset that triggered the corruption |

The live-API verification is the part that matters most here and is the part I
could not repeat. The `startIndex` and `insertPageBreak` findings are both
claims about what Google's API actually returns/does, which no amount of local
mocking settles — the author states both were reproduced before and confirmed
fixed after against the real service, and the corrected mocks are consistent
with those claims.

## Noted

The PR changes a behaviour a test upstream asserted: PATCH-404 on the delete
move now yields `:move_failed` rather than `:drive_file_not_found`. The
reasoning is sound — with the file just fetched, a 404 on the move most likely
names the missing *destination folder*, and conflating the two previously let
deletes DB-trash entries whose live files the next sync resurrected. GET-404
coverage is unchanged.
