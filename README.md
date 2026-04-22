# Document Creator

A [PhoenixKit](https://hex.pm/packages/phoenix_kit) module for document template management and PDF generation via Google Docs. Templates and documents live in Google Drive as Google Docs. Variables use `{{ placeholder }}` syntax and are substituted via the Google Docs API. PDF export uses the Google Drive export endpoint.

## Features

- **Google Docs as editor** — create and edit templates/documents directly in Google Docs
- **Template variables** — `{{ client_name }}`, `{{ date }}` placeholders auto-detected from document text
- **Document creation from templates** — copy a template, fill in variables via API, get a ready document
- **PDF export** — via Google Drive API (no local Chrome/binary dependency)
- **Thumbnail previews** — fetched from Google Drive API for listing cards
- **OAuth 2.0 integration** — connect a Google account in Admin > Settings

## Setup

### 1. Add the dependency

```elixir
# In parent app's mix.exs
{:phoenix_kit_document_creator, "~> 0.2"}
```

### 2. Enable the module

Start your app, go to **Admin > Modules**, enable **Document Creator**.

### 3. Connect Google Docs

1. Create a Google Cloud project with **Docs API** and **Drive API** enabled
2. Create an **OAuth 2.0 Client ID** (Web application type)
3. Go to **Admin > Settings > Document Creator**
4. Enter the Client ID and Client Secret
5. Click **Connect** and authorize the Google account
6. Create `/templates` and `/documents` folders in the connected Google Drive

### Prerequisites

- **Google Cloud project** — with Docs API and Drive API enabled
- **PhoenixKit >= 1.7** — provides the Module behaviour, Settings API, and admin layout

## Architecture

### How it works

```
Template (Google Doc with {{ variables }})
    |  copy via Drive API
    v
Document (Google Doc copy)
    |  replaceAllText via Docs API
    v
Document (variables filled in)
    |  export via Drive API
    v
PDF
```

1. **Templates** are Google Docs stored in a `/templates` folder in Drive. Variables like `{{ client_name }}` are auto-detected from the document text.
2. **Documents** are created by copying a template via the Drive API, then substituting variable values using the Docs API `replaceAllText` endpoint.
3. **PDF export** uses the Drive API file export endpoint — no local Chrome or binary dependencies needed.

### Google Drive as source of truth

All document content lives in Google Drive. The Phoenix app serves as a coordinator:
- Manages OAuth credentials (stored in PhoenixKit Settings)
- Lists files from Drive folders
- Handles variable detection and substitution via API
- Exports PDFs via Drive API
- Displays thumbnails fetched from Drive

### Dependencies

| Package | Purpose |
|---|---|
| `phoenix_kit` | Module behaviour, Settings API, admin layout, Routes |
| `phoenix_live_view` | Admin pages |
| `req` | HTTP client for Google Docs/Drive API |

## Admin Pages

The module registers 3 admin tabs plus a settings tab:

| Page | Path | Description |
|---|---|---|
| **Document Creator** | `/admin/document-creator` | Landing page (redirects to first subtab) |
| **Documents** | `/admin/document-creator/documents` | List documents from Drive with thumbnails |
| **Templates** | `/admin/document-creator/templates` | List templates from Drive with thumbnails |

**Settings:**

| Page | Path | Description |
|---|---|---|
| **Google OAuth** | `/admin/settings/document-creator` | Connect/disconnect Google account, manage OAuth credentials |

## Database Schema

Tables are created by PhoenixKit core's migration system (V86 for the initial
tables, V94 for the `google_doc_id` / `status` / `path` / `folder_id` columns):

### `phoenix_kit_doc_templates`

| Column | Type | Description |
|---|---|---|
| `uuid` | UUID (PK) | Auto-generated (UUIDv7) |
| `name` | string | Template name |
| `slug` | string | URL-safe identifier (unique, auto-generated from name) |
| `description` | text | Template description |
| `status` | string | `"published"`, `"trashed"`, `"lost"`, or `"unfiled"` |
| `google_doc_id` | string | Google Doc ID (partial unique index) |
| `path` | string | Human-readable Drive path (e.g. `"documents/order-1/sub-4"`) |
| `folder_id` | string | Drive folder ID of the file's current parent |
| `variables` | jsonb | Array of variable definitions detected in the template |
| `config` | jsonb | Configuration (e.g., paper_size) |
| `thumbnail` | text | Base64 data URI for preview |
| `content_html` / `content_css` / `content_native` | mixed | Legacy columns — no longer populated |

### `phoenix_kit_doc_documents`

| Column | Type | Description |
|---|---|---|
| `uuid` | UUID (PK) | Auto-generated (UUIDv7) |
| `name` | string | Document name |
| `status` | string | `"published"`, `"trashed"`, `"lost"`, or `"unfiled"` |
| `google_doc_id` | string | Google Doc ID (partial unique index) |
| `path` | string | Human-readable Drive path |
| `folder_id` | string | Drive folder ID of the file's current parent |
| `template_uuid` | UUID (FK) | Template this was created from (optional) |
| `variable_values` | jsonb | Map of variable values used during creation |
| `config` | jsonb | Configuration |
| `thumbnail` | text | Base64 data URI for preview |
| `created_by_uuid` | UUID | Optional FK to users |
| `content_html` / `content_css` / header/footer cols | mixed | Legacy columns — no longer populated |

### `phoenix_kit_doc_headers_footers`

Legacy table — headers and footers are now handled natively by Google Docs.
Retained for migration compatibility; a future migration will drop it.

## Context API

The module exposes three layers. See `AGENTS.md` for the full breakdown; the
quick reference below covers the most common calls.

### `PhoenixKitDocumentCreator.Documents` — combined Drive + DB

Reads go to the local DB (fast); writes go to Drive first then DB. Mutating
functions accept `opts` with `:actor_uuid` for activity logging.

```elixir
# Listing (DB-only, no Drive round-trip)
Documents.list_templates_from_db()
Documents.list_documents_from_db()
Documents.list_trashed_templates_from_db()
Documents.list_trashed_documents_from_db()

# Sync (recursive walker — picks up files nested in subfolders too)
Documents.sync_from_drive()

# Create
Documents.create_template("Invoice Template", actor_uuid: uid)
Documents.create_document("Blank Doc", actor_uuid: uid)

# Create a document from a template, optionally into a subfolder you manage
Documents.create_document_from_template(template_file_id, %{"client" => "Acme"},
  name: "Acme Contract",
  parent_folder_id: sub_folder_id,   # optional — defaults to managed documents root
  path: "documents/order-1/sub-4",   # optional — human-readable path
  actor_uuid: uid
)

# Register a Drive file your own code created (no Drive calls — DB-only upsert)
Documents.register_existing_document(%{
  google_doc_id: doc_id,
  name: "Invoice",
  template_uuid: tpl_uuid,
  variable_values: vars,
  folder_id: sub_folder_id,
  path: "documents/order-1/sub-4"
}, actor_uuid: uid)

Documents.register_existing_template(%{google_doc_id: gid, name: "Tpl"})

# Delete (soft — moves to the deleted folder)
Documents.delete_document(file_id, actor_uuid: uid)
Documents.delete_template(file_id, actor_uuid: uid)
Documents.restore_document(file_id, actor_uuid: uid)
Documents.restore_template(file_id, actor_uuid: uid)

# Unfiled resolution (file found outside the managed tree)
Documents.move_to_templates(file_id, actor_uuid: uid)
Documents.move_to_documents(file_id, actor_uuid: uid)
Documents.set_correct_location(file_id, actor_uuid: uid)

# Variable detection on a template
Documents.detect_variables(file_id)           # {:ok, ["client_name", "date"]}

# PDF export
Documents.export_pdf(file_id, name: "Acme Contract", actor_uuid: uid)

# Folder helpers (cached via Settings, lazy-discovered on first access)
Documents.get_folder_ids()
Documents.refresh_folders()
Documents.templates_folder_url()
Documents.documents_folder_url()

# PubSub — broadcast {:files_changed, self()} on "document_creator:files"
# topic. Bulk callers passing `emit_pubsub: false` to the register functions
# should call this once at the end to resync connected admin LiveViews.
Documents.broadcast_files_changed()
```

### `PhoenixKitDocumentCreator.GoogleDocsClient` — direct Drive + Docs API

OAuth credentials and token refresh live in `PhoenixKit.Integrations` under
the `"google"` provider; this module delegates authentication there.

```elixir
GoogleDocsClient.connection_status()             # {:ok, %{email: ...}} | {:error, reason}
GoogleDocsClient.get_credentials()               # {:ok, creds} | {:error, :not_configured}

# Folders
GoogleDocsClient.find_folder_by_name(name, opts)
GoogleDocsClient.create_folder(name, opts)
GoogleDocsClient.find_or_create_folder(name, opts)
GoogleDocsClient.ensure_folder_path("a/b/c", opts)
GoogleDocsClient.discover_folders()              # resolves all four managed folders
GoogleDocsClient.list_subfolders(parent_id)      # paginated, alphabetical
GoogleDocsClient.list_folder_files(folder_id)    # paginated; direct children only
GoogleDocsClient.get_folder_url(folder_id)

# Files
GoogleDocsClient.create_document(title, parent: folder_id)
GoogleDocsClient.copy_file(src_id, new_name, parent: folder_id)
GoogleDocsClient.move_file(file_id, to_folder_id)
GoogleDocsClient.export_pdf(file_id)             # {:ok, pdf_binary}
GoogleDocsClient.fetch_thumbnail(file_id)        # {:ok, "data:image/png;base64,..."}
GoogleDocsClient.file_status(file_id)            # {:ok, %{trashed: bool, parents: [id]}}
GoogleDocsClient.file_location(file_id)          # {:ok, %{folder_id, path, trashed}}
GoogleDocsClient.get_edit_url(file_id)

# Docs
GoogleDocsClient.get_document(doc_id)
GoogleDocsClient.get_document_text(doc_id)
GoogleDocsClient.batch_update(doc_id, requests)
GoogleDocsClient.replace_all_text(doc_id, %{"var" => "value"})
```

### `PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker` — paginated + recursive traversal

Canonical paginated listing primitive. `list_folder_files/1` and
`list_subfolders/1` on the parent client delegate here.

```elixir
alias PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker

DriveWalker.list_files(folder_id)                # {:ok, [file_map]} — paginated
DriveWalker.list_folders(folder_id)              # {:ok, [folder_map]} — paginated, alphabetical

# BFS the whole tree — returns every descendant folder and every Google Doc
# in any of them, each file annotated with its owning `folder_id` and the
# resolved human-readable `path`.
DriveWalker.walk_tree(root_folder_id,
  root_path: "documents",   # caller-supplied path to anchor descendants at
  max_depth: 20             # defensive cap; root is depth 0
)
```

## Variable System

Templates support `{{ variable_name }}` placeholders.

### Auto-detection

Variables are extracted from Google Doc text content via regex:

```elixir
PhoenixKitDocumentCreator.Variable.extract_variables("Dear {{ client_name }},")
# => ["client_name"]
```

### Type guessing

Variable types are guessed from names:

| Name contains | Guessed type |
|---|---|
| `date` | `:date` |
| `amount`, `price` | `:currency` |
| `description`, `notes` | `:multiline` |
| anything else | `:text` |

## Navigation (Paths Module)

All paths go through `PhoenixKit.Utils.Routes.path/1` via the centralized `Paths` module:

```elixir
alias PhoenixKitDocumentCreator.Paths

Paths.index()                  # /admin/document-creator
Paths.templates()              # /admin/document-creator/templates
Paths.documents()              # /admin/document-creator/documents
Paths.settings()               # /admin/settings/document-creator
```

## PhoenixKit Module Integration

### Behaviour callbacks

| Callback | Value |
|---|---|
| `module_key` | `"document_creator"` |
| `module_name` | `"Document Creator"` |
| `version` | `"0.1.2"` |
| `permission_metadata` | Key: `"document_creator"`, icon: `"hero-document-text"` |
| `children` | `[]` |
| `admin_tabs` | 3 tabs (parent + documents + templates) |
| `settings_tabs` | 1 tab (Google OAuth settings) |

### Permission

The module registers `"document_creator"` as a permission key. Owner and Admin roles get access automatically. Custom roles must be granted access via Admin > Roles.

## Project Structure

```
lib/
  phoenix_kit_document_creator.ex              # Main module (behaviour callbacks, tab registration)
  phoenix_kit_document_creator/
    documents.ex                               # Context: combined Drive + DB operations
    google_docs_client.ex                      # Google Docs + Drive API client (OAuth via Integrations)
    google_docs_client/
      drive_walker.ex                          # Paginated + recursive Drive traversal
    variable.ex                                # Extract {{ variables }} and guess types
    paths.ex                                   # Centralized URL path helpers
    schemas/
      document.ex                              # Document schema
      header_footer.ex                         # Header/footer schema — legacy, deprecated
      template.ex                              # Template schema (with slug auto-gen)
    web/
      documents_live.ex                        # Landing page (templates + documents tabs)
      google_oauth_settings_live.ex            # OAuth settings page
      components/
        create_document_modal.ex               # Multi-step creation modal
```

## Development

### Code quality

```bash
mix format
mix credo --strict
mix dialyzer
```

### Running tests

```bash
# Unit tests only (no database needed)
mix test --exclude integration

# All tests (requires PostgreSQL)
createdb phoenix_kit_document_creator_test
mix test
```

## License

MIT
