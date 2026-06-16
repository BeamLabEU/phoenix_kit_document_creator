# PR #27 Review: Image height arithmetic fix

**Author**: @timujinne
**Reviewer**: @kimi
**URL**: https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/27
**Status**: Merged, no open issues

## Summary

Small, targeted bug-fix PR. The change keeps `height_px` in the image-fill pipeline and adds a nil-safe fallback in `scale_height/3`. Code is clean and the regression tests cover the failure mode.

## Findings

Severity legend: 🔴 must-fix · 🟠 correctness risk · 🟡 efficiency · 🔵 minor.

### 🔵 1. No formal review directory existed

PR #27 was merged without a local review archive under `dev_docs/pull_requests/2026/`. This file adds one retroactively.

### 🔵 2. `build_media_items/1` test seam is acceptable for now

The regression tests reach the private pipeline through a `@doc false` public function. For a focused fix this is fine; a longer-term refactor should expose a real public helper with a documented contract.

## Risk Assessment

**Low.** The change is additive defensiveness around a single arithmetic path; no API or schema changes.

## Recommendation

Approved. No follow-up code changes required.
