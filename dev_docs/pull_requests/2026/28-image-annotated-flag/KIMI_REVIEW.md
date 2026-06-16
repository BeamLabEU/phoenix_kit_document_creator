# PR #28 Review: Per-slot annotated flag for image variables

**Author**: @timujinne
**Reviewer**: @kimi
**URL**: https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/28
**Stats**: +256/−4
**Status**: Merged with no GitHub review; post-merge fixes applied

## Summary

PR #28 adds an `annotated` boolean to image variable config and surfaces it through the existing config pipeline. The normal LiveView flow works: default `true`, checkbox + hidden-false posts the right value, and `image_slots_for_template/1` exposes a string-keyed `config["annotated"]`.

During review a handful of robustness gaps were found and fixed directly on `main`:

1. **`coerce_config/1` now stringifies keys** so atom-keyed caller input does not create mixed/duplicate jsonb keys.
2. **`parse_bool/1` tightened**: `nil`/empty → default `true`; unknown values → `:skip` (preserves existing value) instead of silently coercing to `true`.
3. **`parse_columns/1` tightened** to require whole-string integer parsing, matching `parse_integer/1`.
4. **`resolve_slot_config/3` drops nil saved values** before merging defaults, preventing `%{"annotated" => nil}` from shadowing the default with `nil`.
5. **`VariableConfigForm.config_value/3` treats nil as missing**, so an explicit nil renders the default checked state.
6. **`Variable.image_config_annotated?/1`** added as the canonical host-app accessor.
7. **Integration tests** added for persistence, preservation across unrelated updates, garbage-value rejection, atom-keyed input, and `image_slots_for_template/1` propagation.
8. **CHANGELOG** updated with `0.4.6` and `0.4.7` entries.

## Findings

Severity legend: 🔴 must-fix · 🟠 correctness risk · 🟡 efficiency · 🔵 minor.

### 🔴 1. Atom-keyed config input corrupted stored jsonb (fixed)

`coerce_config/1` only matched string keys. A caller passing `%{annotated: false}` would store both `:annotated` and `"annotated"` after JSON encoding, breaking the uniform string-keyed contract.

### 🟠 2. `parse_bool/1` silently coerced garbage to `true` (fixed)

`parse_bool("maybe")`, `parse_bool(0)`, etc. all became `true`. The fallback is now `:skip` so existing values are preserved; only `nil`/empty default to `true`.

### 🟠 3. Nil saved values could shadow defaults (fixed)

`Map.merge(default, %{"annotated" => nil})` yielded `nil`, which the UI interpreted as unchecked. Nil values are now filtered before merging.

### 🟡 4. No integration coverage for the persistence path (fixed)

Only unit tests existed. Added integration tests for `update_template_variable_config/3` and `image_slots_for_template/1`.

### 🔵 5. `parse_columns/1` accepted partial integers (fixed)

`"2abc"` clamped to `2`; now requires `{n, ""}`.

### 🔵 6. External links lacked `rel` attributes (fixed)

Several `target="_blank"` anchors in `DocumentsLive` were missing `rel="noopener noreferrer"`; all were updated.

## Risk Assessment

**Low–medium.** The fixes are defensive and preserve backward compatibility. The only behavioural change is that malformed `annotated` values now preserve the previous value instead of flipping to `true`.

## Recommendation

Approved with the above follow-ups applied. The remaining `AGENTS.md` TODOs (signed PDF endpoint, inline script → hook, core modal replacement) are unchanged.
