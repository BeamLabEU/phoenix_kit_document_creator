# PR #39 Review — Adopt core's `put_slug/3` for template slugs

**Author:** Max Don (mdon)
**Reviewed:** 2026-08-14 (ecosystem sweep)
**Verdict:** APPROVED — merged, with the core pin raised to `~> 2.4` (a blocker, see below)

> A `phase1.md` from an earlier pass sits alongside this file. Its central call — "do not
> merge until core ships `put_slug/3`" — was correct, and this review resolves it: core
> **2.4.0** shipped `put_slug/3` earlier in this sweep, so the prerequisite is met.

---

## The change

`Template.changeset/2` drops a local `maybe_generate_slug/1` for
`PhoenixKit.Utils.Slug.put_slug(:name, max_length: 255)`. Two real bugs go with it:

- **Renaming a template moved its URL.** The old helper keyed on `get_change(:slug)`
  being nil, which is true both when the caller left the slug alone and when there isn't
  one. Any save carrying no slug re-derived it from the name.
- **Two templates named alike silently shared a slug** — nothing ever probed for
  collisions, so `get-by-slug` broke.

`max_length: 255` is correctly load-bearing (the column is `varchar(255)` and `:name`
allows 255, so an unbounded `-2` suffix overflows and Postgres raises rather than
truncating), and moving `validate_length(:slug)` to *after* generation is right — at its
old position it only ever saw explicitly-cast slugs.

---

## Findings

### BUG - HIGH — the core pin admitted a core without `put_slug/3` *(fixed on main)*

The PR left `pk_dep(:phoenix_kit, "~> 2.0")`, deliberately, pending the core release.
That pin is now actively wrong rather than merely conservative:

`put_slug/3` does not exist before core **2.4.0**. Under `~> 2.0`, a host can legitimately
resolve core 2.0.x and **every save touching `:name` raises `UndefinedFunctionError`** —
and it never fails here, because the workspace always resolves the newest core. This is
the same consumer-only failure shape the umbrella `AGENTS.md` documents for the old
`~> 1.7.x` pins.

Note the PR body's own guidance ("adopters need `~> 2.3`") is off by a minor: 2.3.0 was
already published *without* `put_slug/3`.

**Fix:** pin raised to `~> 2.4` — two-segment, so every later 2.x still satisfies it.

**`core_pin_conformance_test.exs` updated in lock-step**, which is the part worth
explaining rather than just doing. That test asserted the requirement must admit
`2.0.0`/`2.0.7`, so raising the floor makes it fail. Its guard is against the
**three-segment** form (`~> 2.4.0`), which collapses to a single minor and breaks
consumers' `mix deps.get`; a two-segment floor is not that trap. `@must_admit` moves to
`2.4.0 / 2.4.7 / 2.5.0 / 2.9.4` and `@must_reject` gains `2.0.0` and `2.3.0`, so the test
now pins *both* directions: too narrow (single minor) and too wide (a core lacking the
function this module calls). The moduledoc records why.

### IMPROVEMENT - MEDIUM — two `:requires_unreleased_core` tags were inert *(fixed on main)*

The PR tagged its new slug tests `@moduletag :requires_unreleased_core`, and its body
says they are "excluded from normal `mix test`". **They are not.** This repo's
`test_helper.exs` stopped excluding that tag (see its comment at line 153 — the exclusion
was removed at core 2.0 and deliberately not reinstated), so the tag excludes nothing.

So the tests were running all along and would have failed against a Hex-resolved core —
the "masked in CI" reassurance in the PR body did not hold. With the pin at `~> 2.4` the
prerequisite is guaranteed, so both tags were removed rather than left asserting a
condition that is no longer true.

The four `@tag :requires_unreleased_core` in `active_integration_test.exs` are a
different feature (Integrations credential migration) and were left alone.

---

## Verification

- `mix precommit` → exit 0 (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  format, credo `--strict`, dialyzer).
- `mix test` → **854 tests, 0 failures, 1 skipped**, run across three seeds to confirm
  stability. (The very first post-`deps.update` run reported 1 failure and did not
  reproduce on any subsequent run or seed — stale build artefacts, not a real failure.)
- `core_pin_conformance_test.exs` passes against the raised floor.
- The slug tests now exercise the real `put_slug/3` path against the published core
  rather than a locally-pathed one.

The suite's own coverage of the fix is good, and the test file's decision not to pin exact
transliteration output ("what core returns depends on which `phoenix_kit` resolves") is
the right call — it is exactly how `phoenix_kit_dashboards#5` merged red.
