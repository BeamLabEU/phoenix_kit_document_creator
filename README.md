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

Three tables created by the PhoenixKit migration system (V86 for initial tables, V88 for Google Docs fields):

### `phoenix_kit_doc_templates`

| Column | Type | Description |
|---|---|---|
| `uuid` | UUID (PK) | Auto-generated |
| `name` | string | Template name |
| `slug` | string | URL-safe identifier (unique, auto-generated from name) |
| `description` | text | Template description |
| `status` | string | `"published"` or `"trashed"` |
| `content_html` | text | HTML content (cached from Google Doc) |
| `content_css` | text | CSS styles |
| `variables` | jsonb | Array of variable definitions |
| `config` | jsonb | Configuration (e.g., paper_size) |
| `thumbnail` | text | Base64 data URI for preview |
| `google_doc_id` | string | Google Doc ID for API operations |

### `phoenix_kit_doc_documents`

| Column | Type | Description |
|---|---|---|
| `uuid` | UUID (PK) | Auto-generated |
| `name` | string | Document name |
| `template_uuid` | UUID (FK) | Template this was created from (optional) |
| `content_html` | text | HTML content (cached from Google Doc) |
| `content_css` | text | CSS styles |
| `variable_values` | jsonb | Map of variable values used during creation |
| `config` | jsonb | Configuration |
| `thumbnail` | text | Base64 data URI for preview |
| `google_doc_id` | string | Google Doc ID for API operations |
| `created_by_uuid` | UUID | Optional FK to users |

### `phoenix_kit_doc_headers_footers`

| Column | Type | Description |
|---|---|---|
| `uuid` | UUID (PK) | Auto-generated |
| `name` | string | Display name |
| `type` | string | `"header"` or `"footer"` (discriminator) |
| `html` | text | HTML content |
| `css` | text | CSS styles |
| `height` | string | CSS height value (e.g., `"25mm"`) |
| `thumbnail` | text | Base64 data URI for preview |
| `google_doc_id` | string | Google Doc ID for API operations |
| `created_by_uuid` | UUID | Optional FK to users |

## Context API

### `PhoenixKitDocumentCreator.Documents`

All operations go through Google Drive — no local database CRUD for document content.

#### Templates

```elixir
Documents.list_templates()                    # All templates from Drive /templates folder
Documents.create_template(name)               # Create blank Google Doc in /templates
```

#### Documents

```elixir
Documents.list_documents()                    # All documents from Drive /documents folder
Documents.create_document(name)               # Create blank Google Doc in /documents

# Create from template with variable substitution
Documents.create_document_from_template(template_file_id, %{
  "client_name" => "Acme Corp",
  "date" => "2026-03-14"
}, name: "Acme Contract")
# Copies template, replaces {{ variables }}, returns {:ok, %{doc_id, url}}
```

#### Variables

```elixir
Documents.detect_variables(file_id)           # {:ok, ["client_name", "date"]}
```

#### PDF Export

```elixir
Documents.export_pdf(file_id)                 # {:ok, pdf_binary}
```

#### Folders

```elixir
Documents.get_folder_ids()                    # %{templates_folder_id: ..., documents_folder_id: ...}
Documents.refresh_folders()                   # Re-discover from Drive
Documents.templates_folder_url()              # Google Drive URL for templates folder
Documents.documents_folder_url()              # Google Drive URL for documents folder
```

### `PhoenixKitDocumentCreator.GoogleDocsClient`

Low-level Google API client used by the Documents context:

```elixir
GoogleDocsClient.get_credentials()            # {:ok, creds} | {:error, :not_configured}
GoogleDocsClient.authorization_url(redirect)  # {:ok, url} | {:error, :client_id_not_configured}
GoogleDocsClient.exchange_code(code, uri)     # {:ok, creds} (exchanges OAuth code for tokens)
GoogleDocsClient.refresh_access_token()       # {:ok, new_token} (auto-refresh on 401)
GoogleDocsClient.connection_status()          # {:ok, %{email: ...}} | {:error, reason}

GoogleDocsClient.create_document(title, opts) # Create Google Doc in Drive
GoogleDocsClient.copy_file(id, name, opts)    # Copy file in Drive
GoogleDocsClient.replace_all_text(id, vars)   # Substitute {{ variables }} in a Doc
GoogleDocsClient.get_document_text(id)        # Extract plain text for variable detection
GoogleDocsClient.export_pdf(id)               # Export as PDF binary
GoogleDocsClient.fetch_thumbnail(id)          # Fetch thumbnail as base64 data URI
```

## Variable System

Templates support `{{ variable_name }}` placeholders.

### Auto-detection

Variables are extracted from Google Doc text content via regex:

```elixir
PhoenixKitDocumentCreator.Variable.extract_from_html("<p>Dear {{ client_name }},</p>")
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
    documents.ex                               # Context: list/create/export via Google Drive
    google_docs_client.ex                      # Google Docs + Drive API client with OAuth
    variable.ex                                # Extract {{ variables }} and guess types
    paths.ex                                   # Centralized URL path helpers
    schemas/
      document.ex                              # Document schema
      header_footer.ex                         # Header/footer schema (type discriminator)
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
