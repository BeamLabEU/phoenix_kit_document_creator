# PR #3: Add soft delete, configurable folders, and UX improvements

**Author**: @mdon
**Status**: Merged
**Commits**: `c58905e..082bae6` (5 commits)
**Date**: 2026-03-30

## Goal

Add soft-delete for documents and templates (move to Drive trash folders instead of permanent deletion), configurable folder paths with a Google Drive folder browser, and several UX fixes including thumbnail loading crash fix and loading spinners.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/documents.ex` | Added `delete_document/1`, `delete_template/1`, `move_to_deleted_folder/2` for soft delete |
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | Added `move_file/2`, `resolve_folder_path/2`, `list_subfolders/1`, `get_folder_config/0`; extended `find_folder_by_name/2`, `create_folder/2`, `find_or_create_folder/2` with parent option; refactored `discover_folders/0` and `get_folder_ids/0` for 4-folder config; fixed `extract_content_type/1` |
| `lib/phoenix_kit_document_creator/web/components/create_document_modal.ex` | Card styling update, loading spinner for thumbnails |
| `lib/phoenix_kit_document_creator/web/documents_live.ex` | Added `"delete"` event handler, delete buttons in card and list views, loading spinner in thumbnail placeholder |
| `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex` | Full folder config UI with path + name inputs, Drive folder browser modal with breadcrumb navigation |

## Implementation Details

### Soft Delete

Files are moved to `deleted/templates` or `deleted/documents` subfolders in Google Drive rather than permanent deletion. Uses Drive API `PATCH` with `addParents`/`removeParents` params. The deleted folders are auto-created during folder discovery and self-heal if missing (the delete flow re-discovers folders on cache miss).

### Configurable Folders

Folder config is split into **path** (location in Drive hierarchy, e.g. `clients/active`) and **name** (folder name, e.g. `templates`). `resolve_folder_path/2` walks path segments recursively, creating missing folders along the way. Cached folder IDs are cleared when config changes, triggering rediscovery on next use.

### Drive Folder Browser

A modal allows users to visually navigate their Google Drive folder tree to select a path. Uses `list_subfolders/1` API call, breadcrumb navigation, and sends path back to the form on selection. Folder loading is async via `send(self(), {:load_drive_folders, folder_id})`.

### Thumbnail Fix

`extract_content_type/1` now handles Req's map-based header format (`%{"content-type" => [v | _]}`) instead of assuming tuple-based headers, fixing a `FunctionClauseError` across Req versions.
