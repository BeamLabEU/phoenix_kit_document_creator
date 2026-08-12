# Claude Review — PR #35: Keep image markers in range after text substitution shifts the document

Reviewed 2026-08-12 as part of the ecosystem PR sweep. Merged into `main`.

**Verdict: APPROVED.** A correct fix for a real, well-diagnosed bug, with tests
that actually pin the arithmetic. One stale doc reference fixed on `main`; no
other changes needed.

## The bug

`substitute_all_sections/3` runs text substitution, then images. The image
phase re-fetches the document so marker indices are current after the text
edits — but it matched those fresh indices against the section ranges captured
*before* substitution. Since substitution changes the document's length, every
index after an edit moves, and `section_for_match/3` dropped any marker that
had drifted outside its own (now stale) range. The function still returned
`:ok`, so the failure was completely silent.

The PR's diagnosis is measured rather than inferred, which is what makes it
convincing: a marker at 16145 with range `{16080, 16227}` moved to 15975 after
the text phase shortened the document by 170 units, and ten drawings vanished.
It also explains the apparent intermittency — drift accumulates from the
variables in *preceding* sections, so the same templates reordered behave
differently.

## The fix is correct

`shift_ranges/2` moves each boundary by the summed delta of every replacement
starting strictly before it. Verified the index mapping by hand:

- For a boundary at `i` and a replacement over `[s, e)` replaced by a value of
  length `L`, the delta is `L - (e - s)`.
- `i >= e` (boundary after the replacement): `s < i` holds, delta applies. ✔
- `i <= s` (boundary before it): `s < i` is false, no shift. ✔
- A replacement starting exactly on a boundary belongs to the following
  section, and `<` correctly leaves that boundary's start unmoved while still
  moving the section's end. ✔
- A replacement fully inside a section moves that section's end but not its
  start. ✔

All replacement indices come from a single `body_text_runs(doc)` pass on the
one phase-1 fetch, and `ranges` are in that same original coordinate system, so
mapping original → shifted is internally consistent. The split of
`substitute_all_text/4` into `collect_text_replacements/3` +
`apply_text_replacements/2` is what makes the deltas available to phase 2 at
all — the right seam.

`utf16_units/1` is pre-existing and correct (encode to UTF-16, halve the byte
count), which matters because Google Docs indices count surrogate pairs as two.

## The CR sanitization is the subtler half, and it's sound

`insertText` does not store values verbatim — per the API reference Google
strips control characters (U+0000–U+0008, U+000C–U+001F, which includes CR)
and the BMP Private Use Area. A `:multiline` value from a `<textarea>` carries
CRLF, so counting the raw value overstates the delta and drags every later
boundary rightward — the same failure through a different door.

The important property is not that the regex perfectly predicts Google's
behavior; it's that **the sanitized string is used both for the `insertText`
request and for the delta arithmetic**, so the two cannot disagree. Checked the
character ranges: `\x{0009}` (tab), `\x{000A}` (LF) and `\x{000B}` (VT) are
deliberately *not* stripped, which is right — Docs uses them as real content.

Also confirmed the pre-existing empty-value guard still holds after
sanitization: a value that sanitizes down to `""` takes the `"" -> [delete]`
branch, so no `insertText` with empty text is emitted (Google rejects those,
and `batchUpdate` is atomic, so one would void the whole batch).

## The tests earn their keep

Six unit cases plus two end-to-end. Verified each expected number independently:

- The end-to-end case is real: `{{ customer }}` (14 units) → `"Acme"` (4) at
  `[10, 24)` gives delta −10; ranges `%{0 => {1,25}, 1 => {25,46}}` shift to
  `{1,15}` and `{15,36}`, and the marker that moved to 15 lands back inside its
  section. The stub returning a different document on the second `GET` is what
  makes this reachable at all.
- The **supplementary-plane test is the one that matters** and it's easy to
  miss why: `"Kõiv"` is 4 codepoints *and* 4 UTF-16 units, so a
  codepoint-counting implementation would pass the "not bytes" test too. The
  emoji case (`"a🎉b"` — 3 codepoints, 4 units) is what actually separates the
  two. Good test design.
- The boundary-equality case pins the `<` vs `<=` decision, which is exactly
  the edge a future refactor would get wrong.

The PR reports mutation-verification (revert the fix, the new test fails),
which matches what the assertions would do.

No red flags against the Elixir skill's checklist: no process introduced, no
exceptions used for control flow, the new `shift_ranges/2` is a pure function
over data, and `shift_ranges(ranges, [])` short-circuits via a function head
rather than a body conditional.

## Fixed on `main`: stale doc reference

`build_table_batch_requests/2`'s `@doc` pointed at `substitute_all_text/4` as
its sort-order precedent — a function this PR renamed out of existence.
Repointed at `collect_text_replacements/3`, which is where the descending-sort
convention now lives.

## Note: this repo has the version pattern the others should copy

Unrelated to the PR, but worth recording while it's visible. This module does:

```elixir
@version Mix.Project.config()[:version]
def version, do: @version
```

so `version/0` cannot drift from `mix.exs`. Two sibling modules have now
shipped releases whose `version/0` reported an older number
(`phoenix_kit_ai` 0.18.1, `phoenix_kit_catalogue` 0.14.0) because they
hardcode the string in a second place. This is the fix for that class of bug.
