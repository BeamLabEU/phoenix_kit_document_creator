# PR #32 — Fix the #31 slug delegation: it was a silent no-op without `transliterate: true`

**Reviewed:** 2026-08-10 · **Author:** mdon · **Verdict:** merged, no changes
required. Released in **0.5.0**.

+1 / −1. Reviewed as part of the phoenix_kit 2.0 sweep.

## Confirmed against core 2.0.0's source

PR #31 replaced a local ASCII-only slug pipeline with a delegation to core's
`Slug.slugify/1`, and left a comment saying the old pipeline "deleted every
non-ASCII character, so a Cyrillic or Greek name produced an EMPTY slug".
The delegation reintroduced exactly that, because `transliterate` defaults to
**false**. From `deps/phoenix_kit/lib/phoenix_kit/utils/slug.ex`:

```elixir
def slugify(text, opts) when is_binary(text) do
  text
  |> String.downcase()
  |> maybe_transliterate(Keyword.get(opts, :transliterate, false))   # ← false
  |> String.replace(~r/[^a-z0-9]+/u, separator)                      # ← strips the rest
  ...
defp maybe_transliterate(text, true), do: transliterate(text)
defp maybe_transliterate(text, _), do: text
```

With transliteration off, the `[^a-z0-9]+` pass removes every Cyrillic
character, so the slug is empty — the precise bug the comment above the call
claims to have fixed. Passing `transliterate: true` routes the text through
core's Cyrillic map and NFD diacritic strip first.

This is the kind of defect that only shows up in the fix's own stated test case,
which is why it survived review of #31.
