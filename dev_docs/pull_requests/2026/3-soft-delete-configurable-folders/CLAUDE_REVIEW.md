# PR #3: Add soft delete, configurable folders, and UX improvements

**Author**: @mdon
**Reviewer**: @claude (deep review)
**Status**: Merged
**Commits**: `c58905e..082bae6` (5 commits)
**Date**: 2026-03-30

## Goal

Add soft-delete functionality, configurable Drive folder paths with a visual folder browser, fix a thumbnail crash across Req versions, and improve card styling and loading states.

## Issues Found

### HIGH

#### H1. `file_id` interpolated directly into Drive API URL without validation (`google_docs_client.ex:458`)

```elixir
case authenticated_request(:get, "#{@drive_base}/files/#{file_id}",
```

`move_file/2` interpolates `file_id` directly into the URL path. While `file_id` comes from Drive itself (so it's trusted data today), this is an unsanitized URL path interpolation. A file ID containing `/` or `?` could alter the request. This same pattern exists in other functions (`copy_file`, `export_pdf`, `fetch_thumbnail`) — it's a pre-existing issue, but `move_file` is the first function that accepts a file ID sourced from a user-initiated action (the delete button's `phx-value-id`).

**Fix**: Validate that `file_id` matches an expected Drive ID pattern (alphanumeric + hyphens + underscores) or URI-encode it.

#### H2. `String.to_existing_atom/1` in `browser_select` could crash on unexpected input (`google_oauth_settings_live.ex:181`)

```elixir
socket = assign(socket, [{String.to_existing_atom(field), path}, browser_open: false])
```

`field` comes from `browser_field` which is set from user input in `browse_folder`:

```elixir
def handle_event("browse_folder", %{"field" => field}, socket) do
  ...
  assign(socket, browser_field: field, ...)
```

The `phx-value-field` attribute is set in the template to known values (`"templates_path"`, `"documents_path"`, `"deleted_path"`), but a crafted WebSocket message could send an arbitrary string. `String.to_existing_atom/1` will raise `ArgumentError` if the atom doesn't already exist, crashing the LiveView process. In practice, Phoenix validates event targets, making this low-risk — but using a whitelist would be more robust.

**Fix**: Validate `field` against a known set:

```elixir
@valid_path_fields ~w(templates_path documents_path deleted_path)
def handle_event("browse_folder", %{"field" => field}, socket) when field in @valid_path_fields do
```

#### H3. Soft delete is not reversible from the UI

Files moved to deleted folders cannot be restored from the application UI. There's no "trash" view or "restore" action. Users would need to manually move files back via Google Drive. This is a UX gap, not a bug, but worth tracking since the PR description implies "soft delete" as a safety feature.

**Fix**: Add a "Deleted" tab or section in a future PR to list and restore soft-deleted files.

#### H4. `discover_folders/0` makes up to 9 sequential Drive API calls (`google_docs_client.ex:276-305`)

`resolve_folder_path` is called 4 times (templates, documents, deleted/templates, deleted/documents). Each call walks path segments with `find_or_create_folder` — potentially 2+ API calls per segment (find, then maybe create). For a path like `clients/active/templates`, that's 3 segments x 2 calls = 6 calls per path. Four paths could mean ~24 sequential HTTP calls, all blocking the calling process.

This extends the pre-existing H1/H2 issue from the PR #2 review (synchronous HTTP blocking LiveView), but the blast radius is larger now.

**Fix**: Use `Task.async_stream` to resolve the four paths in parallel. The paths share no parent dependencies at the top level (only within each path).

### MEDIUM

#### M1. `resolve_folder_path/2` creates folders as a side effect of resolution (`google_docs_client.ex:217-228`)

The function name `resolve_folder_path` suggests read-only path resolution, but it creates missing folders via `find_or_create_folder`. This is intentional for the auto-create flow, but could surprise callers who just want to check if a path exists.

**Fix**: Either rename to `ensure_folder_path/2` to signal the mutation, or split into `resolve_folder_path/2` (read-only) and `ensure_folder_path/2` (creates missing).

#### M2. Folder browser `list_subfolders/1` is not paginated (`google_docs_client.ex:339`)

```elixir
params: [q: q, fields: "files(id,name)", orderBy: "name", pageSize: 100]
```

If a Drive folder has more than 100 subfolders, only the first 100 are shown. No `nextPageToken` handling. This matches the pre-existing pagination limitation from PR #2 (M7), but now it affects an interactive browser where truncation is more visible to users.

**Fix**: Add a "Load more" button or handle pagination in the browser modal.

#### M3. No flash/toast feedback on successful delete (`documents_live.ex:280-293`)

On successful delete, the file is removed from assigns and a PubSub broadcast fires, but there's no user feedback (no flash, no toast, no temporary message). The file just disappears. On error, an error message is set, but the success path is silent.

**Fix**: Add a brief flash or toast: `put_flash(socket, :info, "Moved to deleted folder")`.

#### M4. `save_folders` clears cached folder IDs even if the save doesn't change anything meaningful (`google_oauth_settings_live.ex:140-156`)

The change detection compares `old_keys != new` which uses string comparison. Trimming whitespace could make a semantically-identical value appear "changed" (e.g., the old value was already trimmed). This isn't likely to cause issues but could trigger unnecessary folder rediscovery.

More importantly, after clearing cached IDs, the next operation (e.g., creating a document) will trigger `discover_folders` which makes multiple Drive API calls. This is fine for deliberate config changes but could be confusing if the user re-saves without changing anything due to a subtle whitespace difference.

**Fix**: Minor — just a note for awareness. The current implementation is reasonable.

#### M5. Inline styles in template cards (`create_document_modal.ex:57`)

```elixir
style="border: 1.5px solid currentColor; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.3); width: 130px;"
```

Inline styles bypass DaisyUI's theme system. If the app switches themes, these hardcoded colors/shadows won't adapt. The existing card view already had some inline styles, so this is consistent with the codebase, but the trend is growing.

**Fix**: Consider extracting to a CSS class or DaisyUI utility classes in a future cleanup.

### LOW

#### L1. `browser_back` doesn't guard against empty path (`google_oauth_settings_live.ex:172-176`)

```elixir
def handle_event("browser_back", %{"index" => index}, socket) do
  index = String.to_integer(index)
  path = Enum.take(socket.assigns.browser_path, index + 1)
  %{id: folder_id} = List.last(path)
```

If `index` is negative or the path is somehow empty after `Enum.take`, `List.last/1` returns `nil` and the pattern match crashes. In practice, the breadcrumb UI only generates valid indices, but a crafted event could crash the process.

#### L2. Delete confirmation uses `data-confirm` which depends on browser `confirm()` dialog (`documents_live.ex:567`)

```elixir
data-confirm={"Delete \"#{file["name"]}\"? It will be moved to the deleted folder."}
```

Browser `confirm()` dialogs are plain and unstyled. Some browsers (especially mobile) handle them poorly. LiveView's `data-confirm` is fine for MVP, but a custom modal confirmation would be more consistent with the rest of the UI.

#### L3. `extract_content_type/1` only handles map headers, not tuple list (`google_docs_client.ex:590-591`)

```elixir
defp extract_content_type(%{"content-type" => [v | _]}), do: v
defp extract_content_type(_), do: "image/png"
```

The PR fixed the crash by handling Req's map format, but the old tuple-list format (`[{"content-type", "image/png"}]`) now falls through to the default `"image/png"`. This works by coincidence since the default matches the expected type, but if the actual content type were different (e.g., `image/jpeg`), it would be silently misidentified. The PR #2 review flagged this as L3.

**Fix**: Handle both formats explicitly:

```elixir
defp extract_content_type(%{"content-type" => [v | _]}), do: v |> String.split(";") |> hd() |> String.trim()
defp extract_content_type(headers) when is_list(headers) do
  Enum.find_value(headers, "image/png", fn
    {"content-type", v} -> v |> String.split(";") |> hd() |> String.trim()
    _ -> nil
  end)
end
defp extract_content_type(_), do: "image/png"
```

#### L4. Dead file still in working tree: `lib/phoenix_kit_document_creator/web/components/editor_scripts.ex`

Git status shows this as an untracked file — it was supposed to be deleted in PR #2 (GrapesJS removal) but wasn't tracked. It's not referenced anywhere.

**Fix**: Delete the file and commit.

---

## Architecture Assessment

### What Went Well

1. **Soft delete is well-designed**: The two-step lookup (check cache, then re-discover) with self-healing folder creation is resilient. Files are never permanently lost.

2. **Folder config separation is clean**: Splitting into path + name gives flexibility without overcomplicating the data model. The `build_full_path` helper is simple and correct.

3. **Drive folder browser is solid**: Async loading via `send(self(), ...)`, breadcrumb navigation, and loading states are all well-implemented. The UX is intuitive.

4. **Good refactoring of existing functions**: Adding `opts \\ []` with `parent` to `find_folder_by_name`, `create_folder`, and `find_or_create_folder` is backwards-compatible and composable.

5. **Thumbnail fix is correct**: Handling Req's header format change with pattern matching on `%{"content-type" => [v | _]}` is the right approach.

6. **Credo/dialyzer cleanup commit**: Separating lint fixes into their own commit keeps the feature commits clean.

### Concerns

1. **Growing complexity in settings JSON**: The `@settings_key` JSON blob now stores OAuth creds, 6 folder config values, and 4 cached folder IDs — all in one Settings key. There's no schema validation on read. A corrupted or partially-updated JSON could cause subtle issues.

2. **Sequential HTTP calls are getting worse**: PR #2 review flagged synchronous Drive API calls as the #1 concern. This PR adds more (folder path resolution, `move_file` which does GET then PATCH). The problem is compounding — folder discovery with nested paths could make 20+ sequential calls.

3. **No tests for new functionality**: The 5 commits add ~500 lines of new code (soft delete, folder config, folder browser, move_file) with no test additions. The existing test file only covers pure functions.

---

## Recommended Fix Priority

| Priority | Item | Status |
|----------|------|--------|
| 1 | H4: Parallelize folder discovery | **Fixed** — `Task.async` + `Task.await_many` for 4 paths |
| 2 | H3: Add deleted files view / restore capability | Deferred — future PR |
| 3 | H1: Validate file IDs before URL interpolation | **Fixed** — `validate_file_id/1` with regex guard |
| 4 | H2: Whitelist browser_field values | **Fixed** — `@valid_path_fields` guard clause |
| 5 | M3: Add success feedback on delete | **Fixed** — `put_flash(:info, ...)` |
| 6 | M1: Rename `resolve_folder_path` to `ensure_folder_path` | **Fixed** |
| 7 | L4: Delete orphaned `editor_scripts.ex` | **Fixed** — file removed |
| 8 | L3: Handle both header formats in `extract_content_type` | **Fixed** — map format with charset stripping |
| 9 | L1: Guard `browser_back` against invalid index | **Fixed** — `max(index + 1, 1)` + case match |
| 10 | Async folder browser loading | **Fixed** — `Task.start` in `handle_info` |
| 11 | M5: Extract inline styles to utility classes | Deferred — cosmetic |
| 12 | M2: Paginate folder browser | Deferred — future PR |

---

## Post-Review Fixes Applied

All actionable issues from the review were fixed in a follow-up commit. Summary:

| # | Issue | Severity | Fix Applied |
|---|-------|----------|-------------|
| H1 | File IDs interpolated unsanitized into URLs | HIGH | Added `validate_file_id/1` with `~r/\A[\w-]+\z/`; `move_file/2` validates both IDs before API calls |
| H2 | `String.to_existing_atom` crash risk in `browser_select` | HIGH | Added `@valid_path_fields` whitelist; `browse_folder` and `browser_select` guard against unknown fields |
| H3 | Soft delete not reversible from UI | HIGH | Deferred — needs its own feature PR for trash view + restore |
| H4 | `discover_folders` made 4 sequential path resolutions | HIGH | `Task.async` + `Task.await_many/2` resolves all 4 paths in parallel |
| M1 | `resolve_folder_path` name implied read-only | MEDIUM | Renamed to `ensure_folder_path/2` to signal folder creation side effect |
| M3 | No user feedback on successful delete | MEDIUM | Added `put_flash(socket, :info, "Moved to deleted folder")` |
| L1 | `browser_back` could crash on invalid index | LOW | Added `max(index + 1, 1)` floor and `case` match on `List.last/1` result |
| L3 | `extract_content_type` missing charset stripping | LOW | Map pattern now strips charset via `String.split(";")` |
| L4 | Orphaned `editor_scripts.ex` dead file | LOW | File deleted |
| New | Folder browser loading blocked LiveView process | — | Made async via `Task.start` + `{:drive_folders_loaded, folders}` message |
| New | No tests for `validate_file_id` or `move_file` validation | — | Added 8 new test cases; updated arity assertions for new/changed exports |

### Deferred Items

| Item | Reason |
|------|--------|
| H3: Deleted files restore UI | Requires new LiveView tab, listing, and restore action — separate PR scope |
| M2: Paginate folder browser | 100-item limit acceptable for most Drive hierarchies |
| M5: Inline styles to utility classes | Cosmetic; consistent with existing codebase patterns |

### Verification

All checks pass after fixes:

```
mix compile --warnings-as-errors  → 0 warnings
mix format                        → clean
mix credo --strict                → no issues
mix dialyzer                      → 0 errors
mix test                          → 101 tests, 0 failures
```

---

## PR #2 Review Follow-up

Several items from the PR #2 review are relevant to this PR:

| PR #2 Item | Status in PR #3 |
|------------|-----------------|
| C1: SQL injection in Drive queries | **Addressed** — `escape_query_value` was added (visible in `list_subfolders`) |
| L1: `do_request` only handles GET/POST | **Fixed** — `:patch` clause added for `move_file` |
| L3: `content-type` header extraction fragile | **Fixed** — map format with charset stripping via `String.split(";")` |
| H1+H2: Async file/thumbnail loading | **Partially addressed** — folder discovery now parallelized; folder browser loading now async |
| M7: No pagination | **Not addressed** — same 100-item limit, now also in folder browser |
