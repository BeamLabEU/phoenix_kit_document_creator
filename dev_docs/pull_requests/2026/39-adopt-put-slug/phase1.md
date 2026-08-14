# PR #39 Phase 1 Review — phoenix_kit_document_creator

**Title:** Adopt core's put_slug/3 for template slugs
**Author:** Max Don (mdon)
**Reviewed:** 2026-08-14
**Verdict:** APPROVE WITH NOTES

---

## Summary

This PR replaces the local `maybe_generate_slug/1` helper in `Template.changeset/2` with
`PhoenixKit.Utils.Slug.put_slug/3` from core (gated on core PR BeamLabEU/phoenix_kit#711).
It fixes two real bugs: (1) renaming a template regenerated its slug and moved the URL, and
(2) two templates with identical names silently shared a slug, breaking `get-by-slug` lookups.

The change is logically correct. The dependency pin deliberately stays `~> 2.0` pending the
core release. **This PR must not be merged until phoenix_kit ships `put_slug/3`** (i.e. core
PR #711 is released to Hex and the lockfile is updated).

---

## Findings

### Blockers

**None** — the PR is merge-safe once the prerequisite core PR #711 ships. The code is correct
and the gating is explicit. However:

> **Pre-merge gate:** Do not merge until `phoenix_kit` releases `put_slug/3` to Hex and
> `mix.lock` is updated. In the current state every `Template.changeset/2` call that touches
> `:name` will raise `UndefinedFunctionError` in production. All affected tests are tagged
> `@moduletag :requires_unreleased_core` and excluded from normal `mix test`, which masks
> this in CI until the lock is updated.

This is documented clearly in the PR body but is worth flagging for the merge checklist.

### Non-blockers

1. **`validate_length(:slug)` ordering** — Correctly moved to *after* `put_slug/3`. At its
   old position (before generation) it only validated explicitly-cast slugs; generated ones
   bypassed it. Now it catches both. `put_slug/3` already truncates to `max_length: 255`, so
   for generated slugs this is a belt-and-suspenders guard, but it correctly catches an
   overlong explicit slug, which the old code also did. No action needed.

2. **No version bump / CHANGELOG** — Intentional per PR body; these are deferred to the
   release that follows core shipping. Acceptable given the sequencing constraint.

3. **`core_pin_conformance_test.exs` referenced but not visible in diff** — The PR body says
   this test guards the `~> 2.0` pin. Verify it exists and covers the case before merging.

4. **`pk_dep/3` precedent** — Consistent with the pattern in `comments` and `posts`. Clean.

5. **Inline comment verbosity in `changeset/2`** — The block comment explaining `max_length`
   and `validate_length` ordering is thorough but unusually long for production code. The
   behaviour is non-obvious (overflow at column boundary, moved validation), so it earns its
   place. Not a change request.

### Nitpicks

- The test `"a blanked slug set via change/2 regenerates from the name"` calls
  `Slug.put_slug/3` directly in the test body rather than going through
  `Template.changeset/2`. This is intentional — it tests the `change/2` path that
  `changeset/2` doesn't expose — but the comment in the test body is doing the explaining
  that a test description usually would. Fine for now.

- Removed tests (`strips special characters`, `collapses multiple hyphens`, etc.) were
  testing internal `slugify/1` behaviour that now belongs to core. Correct to delete them.
  Shape assertions in the integration file are the right replacement.

---

## Stats

| Item | Value |
|---|---|
| Changed files | 4 |
| Additions | +152 |
| Deletions | −58 |
| Tests | New integration suite (`template_slug_test.exs`, 7 tests); existing unit file restructured |
| Migrations | None — unique index already exists |
| Version bump | None (deferred to post-core-release) |
| CHANGELOG | None (deferred) |
| Dependency changes | `mix.exs`: `{:phoenix_kit, "~> 2.0"}` → `pk_dep(:phoenix_kit, "~> 2.0")` (pin unchanged, local-path override helper added) |

---

## Merge Checklist

- [ ] Core PR BeamLabEU/phoenix_kit#711 merged and released to Hex
- [ ] `mix deps.update phoenix_kit` and lockfile committed
- [ ] `mix test` (without `PHOENIX_KIT_PATH`) green — all `requires_unreleased_core` tests now run
- [ ] `core_pin_conformance_test.exs` confirmed present and passing
- [ ] Version bump + CHANGELOG added (or handled in a follow-up release PR)
