# PR #28: Per-slot annotated flag for image variables

**Author**: @timujinne
**Reviewer**: @kimi
**Status**: Merged
**Commit**: `f9a583f` (merge); feature commits `9aa9f6e`, `2118b0b`
**Date**: 2026-06-10

## Goal

Let template authors choose, per image slot, whether inserted images should include flattened annotations (`true`, default and existing behaviour) or use the raw photo (`false`). The library stores and surfaces the flag; the host app is responsible for honouring it when building media URLs.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/variable.ex` | `default_image_config/1` adds `annotated: true` for both `:image` and `:image_list`. |
| `lib/phoenix_kit_document_creator/documents.ex` | `coerce_config/1` parses `"annotated"` via `parse_bool/1`; `image_slots_for_template/1` exposes string-keyed `config["annotated"]`. |
| `lib/phoenix_kit_document_creator/web/components/variable_config_form.ex` | Toggle rendered for `:image` and `:image_list` slots; hidden input ensures unchecked boxes post `"false"`. |
| `test/phoenix_kit_document_creator/annotated_flag_test.exs` | Unit tests for default config, form rendering, and atom/string-keyed lookups. |

## Implementation Details

- The flag is additive: existing templates without the key default to `true`, preserving current behaviour.
- Form values are coerced from `"true"`/`"false"` strings to booleans before storage.
- The saved config is merged into `Variable.default_image_config/1` defaults, so missing keys still resolve correctly.
- Host apps read the effective value via `Variable.image_config_annotated?/1` (added in the follow-up review pass) to avoid depending on key shape.

## Testing

- [x] Unit tests added for default config and form rendering.
- [x] Integration tests added for persistence and `image_slots_for_template/1` propagation.
- [x] Existing suite passes (`mix test --exclude integration`).

## Related

- Previous PR: [#27](/dev_docs/pull_requests/2026/27-image-height-arithmetic-fix/)
