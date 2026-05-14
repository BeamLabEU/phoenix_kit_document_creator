# Root Folder for Document Creator

**Date:** 2026-05-14  
**Status:** Approved

## Problem

Currently all three Drive folders (templates, documents, deleted) are created independently, by default in the root of Google Drive. There is no shared parent folder. This makes it inconvenient to grant collaborators access to project files — you'd have to share individual folders or the entire Drive.

## Goal

Add a single configurable "root folder" that acts as the parent for all Document Creator folders. Users can then share one folder to give access to all project documents.

## Backward Compatibility

**Root folder defaults to empty.** If root is not set, behaviour is identical to today — folders are created at the root of Drive. Existing installations are not affected on upgrade.

## Data Model

Two new fields added to the `document_creator_folders` settings key:

| Key | Default | Description |
|-----|---------|-------------|
| `folder_path_root` | `""` | Parent path in Drive (browse-selected) |
| `folder_name_root` | `""` | Root folder name |

When `folder_name_root` is non-empty, it is prepended to all sub-folder paths before `ensure_folder_path/2` is called. When empty, paths are unchanged.

## Folder Path Resolution

```
# Root empty (current behaviour)
templates  → build_full_path(templates_path, templates_name)
documents  → build_full_path(documents_path, documents_name)
deleted    → build_full_path(deleted_path, deleted_name)

# Root set
root_abs   → build_full_path(root_path, root_name)
templates  → "#{root_abs}/#{build_full_path(templates_path, templates_name)}"
documents  → "#{root_abs}/#{build_full_path(documents_path, documents_name)}"
deleted    → "#{root_abs}/#{build_full_path(deleted_path, deleted_name)}"
```

Sub-folder `path` fields remain configurable (multilingual folder names are preserved).

## Settings UI Changes

### Root folder row

Added at the top of the Drive Folders card, above Templates/Documents/Deleted.
Same layout as existing rows: Browse button (left) + name text input (right).

```
Root folder   [/ Browse]   [________________ my-project _]
──────────────────────────────────────────────────────────
Templates     [/ Browse]   [________________ šabloonid   ]
Documents     [/ Browse]   [________________ dokumendid  ]
Deleted       [/ Browse]   [________________ kustutatud  ]
```

**Default value for name field:** `PhoenixKit.Settings.get_project_title()`, shown as
placeholder text when the field is empty, so the user sees what it will become if saved
without changes but nothing is committed until they actually save.

`browse_folder` event must accept `"root_path"` as a valid `field` value (added to `@valid_path_fields`).

### Access reminder

A static info notice is shown below the form when root folder name is non-empty:

> ℹ️ **Remember to grant access.** After setting up the root folder, share the
> `[root_name]` folder in Google Drive with the users who need access to project
> documents.

This notice is always visible when root is set — not only after migration.

## Migration Flow

Migration is triggered when the user saves settings and **both** conditions are met:

1. `folder_name_root` changed (newly set or renamed)
2. At least one of the existing folder IDs is cached in Settings (i.e. the folders are
   known to exist in Drive)

### Step-by-step

1. `save_folders` detects root changed + cached IDs present → sets `migration_needed: true`
   in socket assigns, does **not** move anything automatically.

2. A migration banner appears below the form:

   > **Found existing folders at their current location.**  
   > Move `templates`, `documents`, and `deleted` into `[root_name]`?  
   > [Move folders] [Skip]

3. User clicks **Move folders** → `handle_event("migrate_folders", ...)`:
   - Creates root folder via `find_or_create_folder/2`
   - For each of the four known folder IDs (templates, documents, deleted_templates,
     deleted_documents): calls `move_file(folder_id, root_folder_id)` via Drive API
   - On success: clears only the four cached folder IDs (`templates_folder_id`,
     `documents_folder_id`, `deleted_templates_folder_id`, `deleted_documents_folder_id`)
     — sub-folder name/path settings are preserved. Folders will be re-discovered under
     the new root on next use. Saves to Settings.
   - Shows success flash: "Folders moved to [root_name]"
   - Shows access reminder (see above)

4. User clicks **Skip** → banner dismissed, `migration_needed: false`. Existing folders
   remain where they are; new root will be used for any newly created folders.

### Error handling

If any individual `move_file` call fails: log the error, show an error alert listing
which folders failed. Do not partially update settings — leave cached IDs intact so the
user can retry.

## GoogleDocsClient Changes

### `get_folder_config/0`

Returns two new keys: `root_path` and `root_name`.

### `discover_folders/0`

Reads `root_name`. If non-empty, builds `root_abs = build_full_path(root_path, root_name)`
and prepends it to each of the four resolved paths before calling `ensure_folder_path/2`.
No change to the parallel Task.Supervisor call structure.

### `migrate_folders_to_root/1` (new)

```elixir
@spec migrate_folders_to_root(String.t()) ::
        {:ok, map()} | {:error, [{:folder, String.t(), term()}]}
```

Accepts the root folder ID. Reads cached folder IDs from Settings. Moves each via
`move_file/2`. Returns `{:ok, %{moved: [...], skipped: [...]}}` or
`{:error, failures}`.

## Activity Logging

| Event key | When |
|-----------|------|
| `settings.folders_changed` | existing — fires on any folder setting save |
| `settings.folders_migrated` | new — fires after successful migrate_folders_to_root |

## Out of Scope

- Changing OAuth Drive scope (remains `https://www.googleapis.com/auth/drive`)
- Moving individual files within folders (only folder-level move)
- Automatic rollback if partial migration fails (user retries manually)
