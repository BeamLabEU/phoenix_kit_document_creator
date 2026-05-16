# Root Folder for Document Creator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a configurable root folder that groups all Document Creator Drive folders under a single parent, with a migration flow to move existing folders.

**Architecture:** Root folder config is stored alongside existing folder settings in the `document_creator_folders` key. `discover_folders/0` prepends the root path when set. The LiveView detects when migration is needed and shows a user-confirmation banner before moving any folders.

**Tech Stack:** Elixir/Phoenix LiveView, Google Drive API v3 (existing `move_file/2`), `PhoenixKit.Settings`.

---

## File Map

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | Extend `get_folder_config/0`; update `discover_folders/0`; add `migrate_folders_to_root/1` |
| `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex` | Add root assigns, root row in form, migration banner, access reminder |
| `test/google_docs_client_test.exs` | Tests for new config keys and `migrate_folders_to_root/1` export |
| `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs` | Tests for root save, migration banner, skip flow |

---

## Task 1: Extend `get_folder_config/0` with root folder fields

**Files:**
- Modify: `lib/phoenix_kit_document_creator/google_docs_client.ex` (function `get_folder_config/0`, ~lines 364–375)
- Test: `test/google_docs_client_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/google_docs_client_test.exs` inside `describe "module interface"`:

```elixir
test "get_folder_config/0 returns root_path and root_name keys" do
  config = GoogleDocsClient.get_folder_config()
  assert Map.has_key?(config, :root_path)
  assert Map.has_key?(config, :root_name)
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /www/phoenix_kit_document_creator && mix test test/google_docs_client_test.exs --no-start 2>&1 | tail -20
```

Expected: failure on `Map.has_key?(config, :root_path)`.

- [ ] **Step 3: Update `get_folder_config/0`**

Replace the body of `get_folder_config/0` in `lib/phoenix_kit_document_creator/google_docs_client.ex`:

```elixir
def get_folder_config do
  creds = Settings.get_json_setting(@folder_settings_key, %{})

  %{
    root_path: creds["folder_path_root"] || "",
    root_name: non_empty(creds["folder_name_root"], ""),
    templates_path: creds["folder_path_templates"] || "",
    templates_name: non_empty(creds["folder_name_templates"], "templates"),
    documents_path: creds["folder_path_documents"] || "",
    documents_name: non_empty(creds["folder_name_documents"], "documents"),
    deleted_path: creds["folder_path_deleted"] || "",
    deleted_name: non_empty(creds["folder_name_deleted"], "deleted")
  }
end
```

Note: `non_empty(val, "")` returns `""` when val is blank — root defaults to empty (no root).

- [ ] **Step 4: Run the test**

```bash
cd /www/phoenix_kit_document_creator && mix test test/google_docs_client_test.exs --no-start 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /www/phoenix_kit_document_creator && git add lib/phoenix_kit_document_creator/google_docs_client.ex test/google_docs_client_test.exs && git commit -m "feat(document-creator): add root_path/root_name to get_folder_config"
```

---

## Task 2: Update `discover_folders/0` to use root folder

**Files:**
- Modify: `lib/phoenix_kit_document_creator/google_docs_client.ex` (function `discover_folders/0`, ~lines 413–485)
- Test: `test/google_docs_client_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/google_docs_client_test.exs` in a new `describe "build_root_prefixed_path/2"` block (this tests the helper we'll extract):

```elixir
describe "root folder path prefixing" do
  test "no root: paths are unchanged" do
    config = %{
      root_path: "", root_name: "",
      templates_path: "", templates_name: "templates",
      documents_path: "clients", documents_name: "docs",
      deleted_path: "", deleted_name: "deleted"
    }

    {t, d, del} = GoogleDocsClient.resolved_folder_paths(config)

    assert t == "templates"
    assert d == "clients/docs"
    assert del == "deleted"
  end

  test "root set: all paths prefixed with root" do
    config = %{
      root_path: "", root_name: "my-project",
      templates_path: "", templates_name: "šabloonid",
      documents_path: "", documents_name: "dokumendid",
      deleted_path: "", deleted_name: "kustutatud"
    }

    {t, d, del} = GoogleDocsClient.resolved_folder_paths(config)

    assert t == "my-project/šabloonid"
    assert d == "my-project/dokumendid"
    assert del == "my-project/kustutatud"
  end

  test "root with path: root path prefixes root name" do
    config = %{
      root_path: "workspace", root_name: "project",
      templates_path: "", templates_name: "templates",
      documents_path: "", documents_name: "documents",
      deleted_path: "", deleted_name: "deleted"
    }

    {t, d, del} = GoogleDocsClient.resolved_folder_paths(config)

    assert t == "workspace/project/templates"
    assert d == "workspace/project/documents"
    assert del == "workspace/project/deleted"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /www/phoenix_kit_document_creator && mix test test/google_docs_client_test.exs --no-start 2>&1 | tail -20
```

Expected: `GoogleDocsClient.resolved_folder_paths/1` undefined.

- [ ] **Step 3: Add `resolved_folder_paths/1` and update `discover_folders/0`**

In `lib/phoenix_kit_document_creator/google_docs_client.ex`, add a new public function just above `discover_folders/0`:

```elixir
@doc "Compute the three Drive paths (templates, documents, deleted) given a folder config map."
@spec resolved_folder_paths(map()) :: {String.t(), String.t(), String.t()}
def resolved_folder_paths(config) do
  root_abs =
    if config.root_name != "" do
      build_full_path(config.root_path, config.root_name)
    else
      nil
    end

  prefix = fn path ->
    if root_abs, do: "#{root_abs}/#{path}", else: path
  end

  templates = prefix.(build_full_path(config.templates_path, config.templates_name))
  documents = prefix.(build_full_path(config.documents_path, config.documents_name))
  deleted   = prefix.(build_full_path(config.deleted_path, config.deleted_name))

  {templates, documents, deleted}
end
```

Then update `discover_folders/0` to use it. Replace the path-building lines (~416–418):

```elixir
def discover_folders do
  config = get_folder_config()

  {templates_path, documents_path, deleted_path} = resolved_folder_paths(config)

  paths = [
    templates_path,
    documents_path,
    "#{deleted_path}/#{config.templates_name}",
    "#{deleted_path}/#{config.documents_name}"
  ]
  # … rest unchanged
```

- [ ] **Step 4: Run the tests**

```bash
cd /www/phoenix_kit_document_creator && mix test test/google_docs_client_test.exs --no-start 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /www/phoenix_kit_document_creator && git add lib/phoenix_kit_document_creator/google_docs_client.ex test/google_docs_client_test.exs && git commit -m "feat(document-creator): prefix all folder paths with root when configured"
```

---

## Task 3: Add `migrate_folders_to_root/1` to GoogleDocsClient

**Files:**
- Modify: `lib/phoenix_kit_document_creator/google_docs_client.ex`
- Test: `test/google_docs_client_test.exs`

- [ ] **Step 1: Write the failing test (export check)**

Add inside `describe "module interface"` in `test/google_docs_client_test.exs`:

```elixir
test "exports migrate_folders_to_root/1" do
  exports = GoogleDocsClient.__info__(:functions)
  assert {:migrate_folders_to_root, 1} in exports
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /www/phoenix_kit_document_creator && mix test test/google_docs_client_test.exs --no-start 2>&1 | tail -10
```

Expected: assertion fails — function not exported.

- [ ] **Step 3: Implement `migrate_folders_to_root/1`**

Add after `get_folder_ids/0` in `lib/phoenix_kit_document_creator/google_docs_client.ex`:

```elixir
@doc """
Move the four known Drive folders (templates, documents, deleted_templates,
deleted_documents) into `root_folder_id`. Only moves folders whose cached ID
is present. Clears cached IDs on full success so they are re-discovered.

Returns `{:ok, %{moved: [labels], skipped: [labels]}}` or
`{:error, [{label, reason}]}` if any move fails.
"""
@spec migrate_folders_to_root(String.t()) ::
        {:ok, %{moved: [String.t()], skipped: [String.t()]}}
        | {:error, [{String.t(), term()}]}
def migrate_folders_to_root(root_folder_id) do
  folder_data = Settings.get_json_setting(@folder_settings_key, %{})

  candidates = [
    {"templates", folder_data["templates_folder_id"]},
    {"documents", folder_data["documents_folder_id"]},
    {"deleted_templates", folder_data["deleted_templates_folder_id"]},
    {"deleted_documents", folder_data["deleted_documents_folder_id"]}
  ]

  {to_move, skipped} =
    Enum.split_with(candidates, fn {_label, id} -> is_binary(id) and id != "" end)

  results =
    Enum.map(to_move, fn {label, folder_id} ->
      case move_file(folder_id, root_folder_id) do
        :ok -> {:ok, label}
        {:error, reason} -> {:error, {label, reason}}
      end
    end)

  failures = for {:error, f} <- results, do: f
  moved = for {:ok, label} <- results, do: label
  skipped_labels = for {label, _} <- skipped, do: label

  if failures == [] do
    cache_keys = ~w(
      templates_folder_id documents_folder_id
      deleted_templates_folder_id deleted_documents_folder_id
    )
    updated = Map.drop(folder_data, cache_keys)
    Settings.update_json_setting_with_module(@folder_settings_key, updated, "document_creator")
    {:ok, %{moved: moved, skipped: skipped_labels}}
  else
    Logger.error("Document Creator folder migration failed: #{inspect(failures)}")
    {:error, failures}
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
cd /www/phoenix_kit_document_creator && mix test test/google_docs_client_test.exs --no-start 2>&1 | tail -10
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd /www/phoenix_kit_document_creator && git add lib/phoenix_kit_document_creator/google_docs_client.ex test/google_docs_client_test.exs && git commit -m "feat(document-creator): add migrate_folders_to_root/1 to GoogleDocsClient"
```

---

## Task 4: Update Settings LiveView — root folder row in form

**Files:**
- Modify: `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex`
- Test: `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs`

- [ ] **Step 1: Write the failing tests**

Add a new `describe "root folder"` block in `google_oauth_settings_live_test.exs`:

```elixir
describe "root folder" do
  test "save_folders persists root folder path and name", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

    render_change(view, "save_folders", %{
      "root_path" => "workspace",
      "root_name" => "my-project",
      "templates_path" => "",
      "templates_name" => "templates",
      "documents_path" => "",
      "documents_name" => "documents",
      "deleted_path" => "",
      "deleted_name" => "deleted"
    })

    state = :sys.get_state(view.pid).socket.assigns
    assert state.root_path == "workspace"
    assert state.root_name == "my-project"
    assert state.success =~ "saved"
  end

  test "browse_folder with root_path field opens the browser modal", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

    render_click(view, "browse_folder", %{"field" => "root_path"})

    state = :sys.get_state(view.pid).socket.assigns
    assert state.browser_open == true
    assert state.browser_field == "root_path"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /www/phoenix_kit_document_creator && mix test test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs 2>&1 | tail -20
```

Expected: failures on `root_path` / `root_name` assigns not found.

- [ ] **Step 3: Add root assigns to `mount/3`**

In `google_oauth_settings_live.ex`, add to the `assign(socket, ...)` call in `mount/3` (after `deleted_name: nil,`):

```elixir
# Root folder
root_path: nil,
root_name: nil,
migration_needed: false,
```

- [ ] **Step 4: Load root config in `load_settings/1`**

In `load_settings/1`, after `fc = GoogleDocsClient.get_folder_config()`, add root to the assign list:

```elixir
root_path: fc.root_path,
root_name: fc.root_name,
```

(alongside the existing `templates_path: fc.templates_path, ...` lines)

- [ ] **Step 5: Handle root in `save_folders`**

In `handle_event("save_folders", params, socket)`, extend `new` map:

```elixir
new = %{
  "folder_path_root"      => String.trim(params["root_path"] || ""),
  "folder_name_root"      => String.trim(params["root_name"] || ""),
  "folder_path_templates" => String.trim(params["templates_path"] || ""),
  "folder_name_templates" => String.trim(params["templates_name"] || ""),
  "folder_path_documents" => String.trim(params["documents_path"] || ""),
  "folder_name_documents" => String.trim(params["documents_name"] || ""),
  "folder_path_deleted"   => String.trim(params["deleted_path"] || ""),
  "folder_name_deleted"   => String.trim(params["deleted_name"] || "")
}
```

Extend the cache-clearing drop list to include root ID (there is none yet, but include for symmetry):

No change needed to the existing `Map.drop` — it only drops the four sub-folder IDs.

Extend the final `assign` in `save_folders` to include:

```elixir
root_path: new["folder_path_root"],
root_name: new["folder_name_root"],
```

- [ ] **Step 6: Add `"root_path"` to `@valid_path_fields`**

```elixir
@valid_path_fields ~w(root_path templates_path documents_path deleted_path)
```

- [ ] **Step 7: Add root row to render**

In `render/1`, add the root folder row **above** the Templates row inside the `<form>` tag. Insert before the Templates `<div class="form-control">`:

```heex
<div class="form-control">
  <label class="label"><span class="label-text">{gettext("Root folder")}</span></label>
  <div class="flex items-center gap-0">
    <button
      type="button"
      class="btn btn-ghost btn-sm font-mono text-sm border border-base-300 rounded-r-none px-2 h-12 max-w-[60%] overflow-hidden"
      phx-click="browse_folder"
      phx-disable-with={gettext("Loading…")}
      phx-value-field="root_path"
      title={if @root_path == "", do: gettext("Browse Google Drive — root"), else: gettext("Browse Google Drive — %{path}", path: @root_path)}
    >
      <span class="hero-folder-open w-4 h-4 shrink-0" />
      <span class="truncate">{if @root_path == "", do: "/", else: "#{@root_path}/"}</span>
    </button>
    <input
      type="text"
      name="root_name"
      value={@root_name}
      class="input input-bordered rounded-l-none flex-1 min-w-0 font-mono text-sm"
      style="min-width: 120px;"
      placeholder={PhoenixKit.Settings.get_project_title()}
    />
    <input type="hidden" name="root_path" value={@root_path} />
  </div>
  <p class="text-xs text-base-content/50 mt-1">
    {gettext("All folders will be created inside this directory.")}
  </p>
</div>

<div class="divider my-1" />
```

Also add the activity log metadata for root in `save_folders` (inside the `if changed` block, extend the metadata map):

```elixir
{:metadata, Map.merge(new, %{"root_path" => new["folder_path_root"], "root_name" => new["folder_name_root"]})}
```

Actually, the existing `{:metadata, new}` already includes the root keys since `new` now has them. No change needed.

- [ ] **Step 8: Run the tests**

```bash
cd /www/phoenix_kit_document_creator && mix test test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 9: Commit**

```bash
cd /www/phoenix_kit_document_creator && git add lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs && git commit -m "feat(document-creator): add root folder row to Drive folder settings form"
```

---

## Task 5: Migration banner with user confirmation

**Files:**
- Modify: `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex`
- Test: `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `describe "root folder"` in `google_oauth_settings_live_test.exs`:

```elixir
test "migration banner appears when root changes and cached folder IDs exist",
     %{conn: conn} do
  # Seed a cached folder ID to simulate existing folders
  PhoenixKit.Settings.update_json_setting_with_module(
    "document_creator_folders",
    %{"templates_folder_id" => "existing-folder-id"},
    "document_creator"
  )

  conn = put_test_scope(conn, fake_scope())
  {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

  render_change(view, "save_folders", %{
    "root_path" => "",
    "root_name" => "my-project",
    "templates_path" => "",
    "templates_name" => "templates",
    "documents_path" => "",
    "documents_name" => "documents",
    "deleted_path" => "",
    "deleted_name" => "deleted"
  })

  assert :sys.get_state(view.pid).socket.assigns.migration_needed == true
end

test "skip_migration dismisses the banner", %{conn: conn} do
  PhoenixKit.Settings.update_json_setting_with_module(
    "document_creator_folders",
    %{"templates_folder_id" => "existing-folder-id"},
    "document_creator"
  )

  conn = put_test_scope(conn, fake_scope())
  {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

  render_change(view, "save_folders", %{
    "root_path" => "",
    "root_name" => "my-project",
    "templates_path" => "",
    "templates_name" => "templates",
    "documents_path" => "",
    "documents_name" => "documents",
    "deleted_path" => "",
    "deleted_name" => "deleted"
  })

  render_click(view, "skip_migration", %{})
  assert :sys.get_state(view.pid).socket.assigns.migration_needed == false
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /www/phoenix_kit_document_creator && mix test test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs 2>&1 | tail -20
```

Expected: `migration_needed` assertion failures.

- [ ] **Step 3: Add migration detection to `save_folders`**

At the end of `handle_event("save_folders", ...)`, after assigning success, add migration check. Replace:

```elixir
{:noreply,
 assign(socket,
   root_path: new["folder_path_root"],
   root_name: new["folder_name_root"],
   ...
   success: gettext("Folder settings saved"),
   error: nil
 )}
```

With:

```elixir
old_root_name = socket.assigns.root_name || ""
new_root_name = new["folder_name_root"]
root_changed = changed and new_root_name != "" and new_root_name != old_root_name

folder_data_after = Settings.get_json_setting(GoogleDocsClient.folder_settings_key(), %{})
has_cached_ids =
  Enum.any?(
    ~w(templates_folder_id documents_folder_id deleted_templates_folder_id deleted_documents_folder_id),
    &(is_binary(folder_data_after[&1]) and folder_data_after[&1] != "")
  )

{:noreply,
 assign(socket,
   root_path: new["folder_path_root"],
   root_name: new["folder_name_root"],
   templates_path: new["folder_path_templates"],
   templates_name: new["folder_name_templates"],
   documents_path: new["folder_path_documents"],
   documents_name: new["folder_name_documents"],
   deleted_path: new["folder_path_deleted"],
   deleted_name: new["folder_name_deleted"],
   migration_needed: root_changed and has_cached_ids,
   success: gettext("Folder settings saved"),
   error: nil
 )}
```

- [ ] **Step 4: Add `skip_migration` and `migrate_folders` event handlers**

Add after `save_folders` handler:

```elixir
def handle_event("skip_migration", _params, socket) do
  {:noreply, assign(socket, migration_needed: false)}
end

def handle_event("migrate_folders", _params, socket) do
  root_name = socket.assigns.root_name
  root_path = socket.assigns.root_path || ""

  root_abs =
    if root_path != "", do: "#{root_path}/#{root_name}", else: root_name

  case GoogleDocsClient.ensure_folder_path(root_abs) do
    {:ok, root_folder_id} ->
      case GoogleDocsClient.migrate_folders_to_root(root_folder_id) do
        {:ok, %{moved: moved}} ->
          Documents.log_manual_action("settings.folders_migrated", [
            {:actor_uuid, actor_uuid(socket)},
            {:metadata, %{"root_name" => root_name, "moved" => moved}}
          ])

          {:noreply,
           assign(socket,
             migration_needed: false,
             success: gettext("Folders moved to "%{name}"", name: root_name),
             error: nil
           )}

        {:error, failures} ->
          labels = Enum.map_join(failures, ", ", fn {label, _} -> label end)

          {:noreply,
           assign(socket,
             error: gettext("Migration failed for: %{folders}", folders: labels),
             success: nil
           )}
      end

    {:error, _reason} ->
      {:noreply,
       assign(socket,
         error: gettext("Could not create root folder "%{name}"", name: root_name),
         success: nil
       )}
  end
end
```

- [ ] **Step 5: Render the migration banner**

Add inside `render/1`, between the flash messages block and the Google Account card:

```heex
<%!-- Migration banner --%>
<div :if={@migration_needed} class="alert alert-warning">
  <span class="hero-exclamation-triangle w-5 h-5" />
  <div>
    <p class="font-semibold">{gettext("Existing folders found at their current location.")}</p>
    <p class="text-sm">{gettext("Move templates, documents, and deleted into "%{name}"?", name: @root_name)}</p>
  </div>
  <div class="flex gap-2 ml-auto">
    <button class="btn btn-ghost btn-sm" phx-click="skip_migration">{gettext("Skip")}</button>
    <button
      class="btn btn-warning btn-sm"
      phx-click="migrate_folders"
      phx-disable-with={gettext("Moving…")}
    >
      {gettext("Move folders")}
    </button>
  </div>
</div>
```

- [ ] **Step 6: Run the tests**

```bash
cd /www/phoenix_kit_document_creator && mix test test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
cd /www/phoenix_kit_document_creator && git add lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs && git commit -m "feat(document-creator): migration banner with user-confirmed folder move"
```

---

## Task 6: Access reminder notice

**Files:**
- Modify: `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex`
- Test: `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `describe "root folder"` in `google_oauth_settings_live_test.exs`:

```elixir
test "access reminder is visible when root name is set", %{conn: conn} do
  conn = put_test_scope(conn, fake_scope())
  {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

  render_change(view, "save_folders", %{
    "root_path" => "",
    "root_name" => "my-project",
    "templates_path" => "",
    "templates_name" => "templates",
    "documents_path" => "",
    "documents_name" => "documents",
    "deleted_path" => "",
    "deleted_name" => "deleted"
  })

  html = render(view)
  assert html =~ "grant access"
end

test "access reminder is not visible when root name is empty", %{conn: conn} do
  conn = put_test_scope(conn, fake_scope())
  {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

  html = render(view)
  refute html =~ "grant access"
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /www/phoenix_kit_document_creator && mix test test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs 2>&1 | tail -20
```

Expected: `html =~ "grant access"` assertion fails.

- [ ] **Step 3: Add the access reminder to `render/1`**

Add inside the `<div :if={@connected}>` Drive Folders card, just **below** the `</form>` closing tag and before the closing `</div>` of the card body:

```heex
<div :if={@root_name && @root_name != ""} class="alert alert-info mt-4">
  <span class="hero-information-circle w-5 h-5" />
  <span>
    {gettext("Remember to grant access.")}
    {gettext(
      "Share the \"%{name}\" folder in Google Drive with the users who need access to project documents.",
      name: @root_name
    )}
  </span>
</div>
```

- [ ] **Step 4: Run the tests**

```bash
cd /www/phoenix_kit_document_creator && mix test test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 5: Run the full test suite**

```bash
cd /www/phoenix_kit_document_creator && mix test --no-start 2>&1 | tail -30
```

Expected: all tests pass. If any compilation errors appear (e.g. unused variable warnings promoted to errors), fix them before committing.

- [ ] **Step 6: Commit**

```bash
cd /www/phoenix_kit_document_creator && git add lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs && git commit -m "feat(document-creator): show access reminder when root folder is configured"
```

---

## Self-Check

After all tasks complete, verify:

- [ ] `mix test --no-start` passes with no failures
- [ ] `mix format --check-formatted` passes
- [ ] Settings page renders root folder row above Templates
- [ ] Saving root name with existing cached IDs shows the migration banner
- [ ] "Skip" dismisses banner without moving anything
- [ ] Access reminder shows when root name is non-empty, hidden when empty
- [ ] Saving with empty root name: same behaviour as before this feature (backward-compat check)
