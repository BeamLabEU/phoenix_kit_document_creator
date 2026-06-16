# PR #27: Image height arithmetic fix

**Author**: @timujinne
**Reviewer**: @kimi
**Status**: Merged
**Commit**: `ef12bc1` (merge); feature commits `ecb710d`, `e4d0e64`, `669069b`, `e90ae97`
**Date**: 2026-06-09

## Goal

Prevent image substitution from dividing by `nil` when a media item's source height is missing, and harden the height-scaling path so both inline and table-grid image rendering use a single, consistent config lookup.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | `build_media_items/1` now carries `height_px` through to the image-fill map; `scale_height/3` falls back safely when source height is missing; config lookup centralised for width/height. |
| `test/integration/google_docs_client/image_substitution_test.exs` | Regression tests pinning `450.0 PT` rendered height and `height_px` propagation. |

## Implementation Details

- `build_media_items/1` previously dropped `height_px` after calculating the PT-scaled width, leaving `scale_height/3` with no denominator if it was later re-derived. The fix keeps `height_px` in the media item so downstream helpers always have source dimensions.
- `scale_height/3` now guards against `nil` height and falls back to the configured/default height rather than raising.
- Width/height config is read through a single helper so atom/string key handling is consistent in both the inline and table-grid paths.

## Testing

- [x] Unit/integration tests added for `build_media_items/1` carrying `height_px`.
- [x] Regression test pins exact rendered height (`450.0 PT`).
- [x] Existing suite passes (`mix test --exclude integration`).

## Related

- Previous PR: [#21](/dev_docs/pull_requests/2026/21-image-columns-config-sidebar/)
- Follow-up: [#28](/dev_docs/pull_requests/2026/28-image-annotated-flag/)
