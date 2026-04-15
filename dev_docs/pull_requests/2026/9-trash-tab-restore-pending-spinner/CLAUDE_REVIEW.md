# PR #9 Review: Trash tab with restore, pending spinner, layout polish

**Author**: mdon (Max Don)
**URL**: https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/9
**Stats**: +539 / -95

## Overview

Adds soft-delete recovery — `list_trashed_*_from_db/0`, `restore_template/2`, `restore_document/2`, Active/Trash status tabs in `DocumentsLive`, async pending-spinner UX, and misc polish (PDF DOM fix, `phx-disable-with`, catch-all `handle_info`, sort-by-`inserted_at` workaround with documented TODOs).

## Strengths

- **Nice symmetry**: `restore_*` mirrors `delete_*` cleanly via `move_from_deleted_folder/2`; activity logging preserved.
- **Good data-driven refactor**: `action_spec/2` + `apply_optimistic_move/3` collapses four copy-paste branches into one table. Substantial readability win over pre-PR `do_delete`.
- **Security**: `verify_known_file` is correctly extended to the trashed lists, so restore can't be spoofed with an arbitrary ID.
- **UX**: dimmed card + absolute-positioned spinner keeps layout stable during async actions; auto-hide tabs when empty; PDF anchor attach is a real bug fix (Firefox/some browsers require DOM attachment before `.click()`).
- **Tests**: cover the new query functions (trashed-only filter, excludes nil `google_doc_id`, empty case).
- **Documented workarounds**: AGENTS.md TODOs explain the `inserted_at` sort and the `drive_modified_at` long-term fix — good context-preservation for future maintainers.

## Issues / Suggestions

### 1. `apply_optimistic_move` is misnamed
It runs *after* `spec.backend.()` succeeds, so it's not optimistic. Either make it truly optimistic (move immediately, roll back on `{:error, _}`) or rename to `apply_move/3`. Today the card spins through the full Drive round-trip with no visible list change; the "optimistic" label suggests otherwise.

### 2. Catch-all `handle_info(_msg, socket)` is too broad
Swallows *everything* — including future bugs and unexpected `DOWN`/monitor messages. Prefer:

```elixir
def handle_info(msg, socket) do
  Logger.debug("unexpected LiveView message: #{inspect(msg)}")
  {:noreply, socket}
end
```

PR description frames this as crash prevention; silent drop is a worse failure mode than a crash in dev.

### 3. Error path: no rescue for raised exceptions
If `spec.backend.()` raises (not just returns `{:error, _}`), the LiveView crashes and `pending_files` is stale on remount. Current behavior relies on the process crashing cleanly — confirm that's the intent, or wrap with `try/rescue`.

### 4. Test coverage gap for restore path
No tests for `restore_template/2` / `restore_document/2` themselves, nor the `"trashed"` ordering. The happy path relies on `GoogleDocsClient.move_file` which isn't exercised here. Add at least a unit-ish test with a stubbed client, matching the pattern used for `delete_*`.

### 5. `inserted_at DESC` ordering surprise after restore
A restored item sorts by its *original* insert time, so a just-restored old doc sinks to the bottom of Active — users likely expect it at the top. The `drive_modified_at` migration in the TODO addresses this; worth calling out explicitly in the PR description so it's tracked as a known UX limitation until then.

### 6. Minor: thumbnail ID set is now 2× larger on mount
`all_ids` includes trashed files on every mount/sync. Harmless at current scale, but pairs with the AGENTS.md index TODOs — once the tables grow, consider lazy-loading trash thumbnails only when the trash tab is opened.

### 7. Minor: heex readability
`active_count` / `trashed_count` / `all_status_tabs` / `visible_status_tabs` computed as inline `<% %>` bindings is noisy. Consider a `status_tabs/1` private component or computing in `assign_files`.

## Risk Assessment

**Low.** Changes are additive; existing delete flow preserved semantically. Main watch-items:
- Catch-all `handle_info` (observability risk)
- Absence of restore-path unit tests (correctness risk on Drive API changes)
- `inserted_at` ordering behavior post-restore (UX expectation)

## Recommendation

Approve with the above addressed as follow-ups, or request the catch-all `handle_info` logging change + restore test before merge — both are quick. The refactor is a net-positive for maintainability.
