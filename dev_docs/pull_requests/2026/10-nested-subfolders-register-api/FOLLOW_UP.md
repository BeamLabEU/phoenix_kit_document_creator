# PR #10 Follow-Up — Nested Subfolders + Register API

CLAUDE_REVIEW.md flagged six items across correctness and coverage. Audit:

## Fixed (pre-existing)

- ~~**Group A #1 — `rescue _ -> nil` too broad in walker**~~ — narrowed to specific exception types in commit `becd95d` ("Harden test setup and narrow Documents.default_managed rescue").
- ~~**Group A #2 — BFS queue O(n²) via list `++`**~~ — replaced with the `:queue` module in commit `56d5c66` ("Batch folder discovery in DriveWalker"). Verified: `GoogleDocsClient.DriveWalker.walk_tree/2` uses `:queue.in/2` / `:queue.out/1`.
- ~~**Group A #3 — `test_helper.exs` missing `psql` guard**~~ — `try/rescue ErlangError` added around `System.cmd("psql", …)` in commit `becd95d`.
- ~~**Group B #5 — Folder discovery batching**~~ — level-based BFS with batched `'a' in parents or 'b' in parents …` queries (chunked at 40 IDs per request). Verified in `DriveWalker.walk_tree/2` and `discover_subfolders/2`.

## Skipped (with rationale)

- **Coverage #1 — No walker HTTP-stub test**. Folded into Phase 2 C8 (unit/integration tests for helpers). Tests for `DriveWalker.walk_tree/2` will land with a `Req.Test`-style stub when the test infra is built out, not parked here.
- **Coverage #2 — No test for `create_document_from_template/3` new options** (`:parent_folder_id`, `:path`). Same disposition — Phase 2 C10 LV smoke tests will cover the option threading from the modal.

## Open

None. Both coverage items are folded into Phase 2's planned C8/C10 work, not parked here.
