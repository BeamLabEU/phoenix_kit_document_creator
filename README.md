# Document Creator

A [PhoenixKit](https://hex.pm/packages/phoenix_kit) module for visual document design and PDF generation. Build reusable templates with a drag-and-drop editor (GrapesJS), define `{{ variables }}` that get filled in when creating documents, design custom headers and footers, and export to PDF via ChromicPDF.

## Features

- **Visual template editor** — GrapesJS drag-and-drop page builder with live preview
- **Template variables** — `{{ client_name }}`, `{{ date }}` placeholders auto-detected and rendered via Solid (Liquid syntax)
- **Document creation from templates** — pick a template, fill in variables, get a pre-rendered document
- **Reusable headers & footers** — design once, assign to multiple templates
- **PDF export** — ChromicPDF (headless Chrome) with paper size selection and header/footer support
- **Multi-page support** — visual page breaks with page count management
- **Thumbnail previews** — scaled page previews on listing cards
- **Paper sizes** — A4, Letter, Legal, Tabloid (96 DPI standard across JS, Elixir, and CSS)

## Setup

### 1. Add the dependency

```elixir
# In parent app's mix.exs
{:phoenix_kit_document_creator, "~> 0.2"}

# For local development:
# {:phoenix_kit_document_creator, path: "../phoenix_kit_document_creator"}
```

### 2. Install and migrate

```bash
mix deps.get
mix phoenix_kit_document_creator.install   # Creates migration file
mix ecto.migrate                            # Creates database tables
```

### 3. Enable the module

Start your app, go to **Admin > Modules**, enable **Document Creator**.

### Prerequisites

- **Chrome or Chromium** — required for PDF generation. The module loads and compiles without it, but PDF export will show an error.
- **PhoenixKit >= 1.7** — provides the Module behaviour, Settings API, and admin layout.

## Architecture

### How it works

```
Template (GrapesJS HTML + CSS + variables)
    ↓ fill in {{ variables }} via Solid
Document (rendered HTML + CSS)
    ↓ ChromicPDF (headless Chrome)
PDF (with optional header/footer)
```

1. **Templates** store HTML, CSS, and GrapesJS native project data. Variables like `{{ client_name }}` are auto-detected from the content.
2. **Documents** are created from templates by substituting variable values via Solid (Liquid template engine). The rendered HTML is stored so documents can be further edited.
3. **Headers & Footers** are separate designs with configurable height (CSS units like `"25mm"`). They're assigned to templates/documents via FK and rendered in the PDF margins.
4. **PDF export** uses ChromicPDF with Chrome DevTools Protocol. Paper dimensions use the CSS standard (1in = 96px, 1mm = 3.7795px).

### Lazy Chrome startup

ChromicPDF is started **lazily** via `PhoenixKitDocumentCreator.ChromeSupervisor`. Chrome only launches when someone actually generates a PDF, not at app boot. This keeps things lightweight when the module is enabled but not actively used. If Chrome isn't installed, the module still loads — PDF generation returns a clear error.

### Dependencies

| Package | Purpose |
|---|---|
| `phoenix_kit` | Module behaviour, Settings API, admin layout, Routes |
| `phoenix_live_view` | Admin pages |
| `chromic_pdf` | HTML → PDF via headless Chrome |
| `solid` | Liquid template engine for `{{ variable }}` substitution |

## Admin Pages

The module registers 13 admin tabs (10 base + 3 conditional testing tabs):

| Page | Path | Description |
|---|---|---|
| **Documents** | `/admin/document-creator` | Landing page with Templates and Documents tabs, grid cards with thumbnails |
| **New Template** | `/admin/document-creator/templates/new` | GrapesJS editor for new template |
| **Edit Template** | `/admin/document-creator/templates/:uuid/edit` | GrapesJS editor for existing template |
| **Edit Document** | `/admin/document-creator/documents/:uuid/edit` | GrapesJS editor for document content |
| **Headers** | `/admin/document-creator/headers` | List of header designs (subtab) |
| **New Header** | `/admin/document-creator/headers/new` | GrapesJS header editor |
| **Edit Header** | `/admin/document-creator/headers/:uuid/edit` | GrapesJS header editor |
| **Footers** | `/admin/document-creator/footers` | List of footer designs (subtab) |
| **New Footer** | `/admin/document-creator/footers/new` | GrapesJS footer editor |
| **Edit Footer** | `/admin/document-creator/footers/:uuid/edit` | GrapesJS footer editor |

### Testing editors (optional)

Alternative editors are available behind a config flag for comparison:

```elixir
config :phoenix_kit_document_creator, :testing_editors, true
```

| Page | Path | Description |
|---|---|---|
| **Testing Hub** | `/admin/document-creator/testing` | Editor comparison page |
| **pdfme Test** | `/admin/document-creator/testing/pdfme` | JSON-based PDF form editor |
| **TipTap Test** | `/admin/document-creator/testing/tiptap` | Rich text editor alternative |

These load from CDN — no extra mix dependencies needed.

## Database Schema

Three tables created by the migration system (currently at V03):

### `phoenix_kit_doc_headers_footers`

| Column | Type | Description |
|---|---|---|
| `uuid` | UUID (PK) | Auto-generated |
| `name` | string | Display name |
| `type` | string | `"header"` or `"footer"` (discriminator) |
| `html` | text | Rendered HTML content |
| `css` | text | CSS styles |
| `native` | jsonb | GrapesJS project data (for re-editing) |
| `height` | string | CSS height string (e.g., `"25mm"`, `"1in"`) |
| `data` | jsonb | Custom metadata |
| `thumbnail` | text | Base64 data URI for preview |
| `created_by_uuid` | UUID | Optional FK to users |

### `phoenix_kit_doc_templates`

| Column | Type | Description |
|---|---|---|
| `uuid` | UUID (PK) | Auto-generated |
| `name` | string | Template name |
| `slug` | string | URL-safe identifier (unique, auto-generated from name) |
| `description` | text | Template description |
| `status` | string | `"published"` or `"trashed"` |
| `content_html` | text | HTML with `{{ variable }}` placeholders |
| `content_css` | text | CSS styles |
| `content_native` | jsonb | GrapesJS project data |
| `variables` | jsonb | Array of `{name, label, type, default}` objects |
| `header_uuid` | UUID (FK) | Optional header design |
| `footer_uuid` | UUID (FK) | Optional footer design |
| `config` | jsonb | `{paper_size, orientation, page_count}` |
| `data` | jsonb | Custom metadata |
| `thumbnail` | text | Base64 data URI for preview |

### `phoenix_kit_doc_documents`

| Column | Type | Description |
|---|---|---|
| `uuid` | UUID (PK) | Auto-generated |
| `name` | string | Document name |
| `template_uuid` | UUID (FK) | Template this was created from (optional) |
| `content_html` | text | Rendered HTML (variables already substituted) |
| `content_css` | text | CSS styles |
| `content_native` | jsonb | GrapesJS project data |
| `variable_values` | jsonb | Map of `{variable_name => value}` used during creation |
| `header_uuid` | UUID (FK) | Optional header design |
| `footer_uuid` | UUID (FK) | Optional footer design |
| `config` | jsonb | `{paper_size, orientation, page_count}` |
| `data` | jsonb | Custom metadata |
| `thumbnail` | text | Base64 data URI for preview |
| `created_by_uuid` | UUID | Optional FK to users |

Note: The `status` column exists in the database (added by V01 migration with default `"draft"`) but is not currently exposed in the Ecto schema — documents don't use status-based filtering.

## Context API

### `PhoenixKitDocumentCreator.Documents`

#### Templates

```elixir
Documents.list_templates()                    # All non-trashed, ordered by updated_at
Documents.list_templates(status: "published") # Filter by status
Documents.get_template(uuid)                  # Get by UUID (nil if not found)
Documents.create_template(attrs)              # {:ok, template} | {:error, changeset}
Documents.update_template(template, attrs)    # {:ok, template} | {:error, changeset}
Documents.delete_template(template)           # {:ok, template} | {:error, changeset}
```

#### Documents

```elixir
Documents.list_documents()                    # All documents, ordered by updated_at
Documents.get_document(uuid)                  # Get by UUID
Documents.create_document(attrs)              # {:ok, document} | {:error, changeset}
Documents.update_document(document, attrs)    # {:ok, document} | {:error, changeset}
Documents.delete_document(document)           # {:ok, document} | {:error, changeset}

# Create from template with variable substitution
Documents.create_document_from_template(template_uuid, %{
  "client_name" => "Acme Corp",
  "date" => "2026-03-14"
}, name: "Acme Contract")
# Returns {:ok, document} | {:error, :template_not_found} | {:error, changeset}
```

#### Headers & Footers

```elixir
Documents.list_headers()                      # All headers, ordered by name
Documents.list_footers()                      # All footers, ordered by name
Documents.get_header_footer(uuid)             # Get by UUID (either type)
Documents.create_header(attrs)                # Automatically sets type: "header"
Documents.create_footer(attrs)                # Automatically sets type: "footer"
Documents.update_header_footer(hf, attrs)     # {:ok, hf} | {:error, changeset}
Documents.delete_header_footer(hf)            # {:ok, hf} | {:error, changeset}
```

## Variable System

Templates support `{{ variable_name }}` placeholders using Liquid/Solid syntax.

### Auto-detection

Variables are extracted from template HTML via regex:

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

### Rendering

When creating a document from a template, variables are rendered via Solid (Liquid engine). If Solid parsing fails (e.g., HTML contains Liquid-incompatible syntax), it falls back to regex substitution.

## PDF Generation

### `EditorPdfHelpers.generate_pdf/2`

```elixir
EditorPdfHelpers.generate_pdf(html,
  paper_size: "a4",           # "a4" | "letter" | "legal" | "tabloid"
  header_html: "<div>...</div>",
  footer_html: "<div>...</div>",
  header_height: "25mm",
  footer_height: "20mm"
)
# Returns {:ok, base64_pdf} | {:error, reason}
```

### Paper sizes

| Size | Dimensions (CSS pixels at 96 DPI) | Inches |
|---|---|---|
| A4 | 794 x 1123 | 8.27 x 11.69 |
| Letter | 816 x 1056 | 8.5 x 11 |
| Legal | 816 x 1344 | 8.5 x 14 |
| Tabloid | 1056 x 1632 | 11 x 17 |

### Unit conversion

Three unit systems are used, all based on the CSS standard of 1in = 96px:

| System | Where | Example |
|---|---|---|
| CSS pixels | GrapesJS canvas (`editor_hooks.js`) | A4 = 794 x 1123px |
| Inches | ChromicPDF `paperWidth`/`paperHeight` | A4 = 8.27 x 11.69in |
| CSS units | Header/footer heights | `"25mm"`, `"1in"` |

All resolve to the same physical dimensions (1mm = 3.7795px = 1/25.4in).

## JavaScript Architecture

### Base64-encoded compile-time delivery

The GrapesJS editor hooks are delivered via a base64-encoded compile-time embedding pattern. The JS source (`editor_hooks.js`) is read and encoded at compile time by `EditorScripts`, then emitted as a `data-` attribute on a hidden `<div>`. A tiny inline bootstrapper decodes and executes it.

**Why not inline `<script>` tags?**

1. LiveView's morphdom breaks `</script>` boundaries during connected render
2. HTML strings inside JS confuse the rendering pipeline
3. Browser extensions (MetaMask etc.) block `eval()` from inline scripts

See `EditorScripts` moduledoc for full details.

**Editing the JS:**

1. Edit `lib/phoenix_kit_document_creator/web/components/editor_hooks.js`
2. From parent app: `mix deps.compile phoenix_kit_document_creator --force`
3. Restart the Phoenix server

### GrapesJS integration

GrapesJS is loaded dynamically from CDN on first use. The editor hooks provide:

- **Paper size management** — canvas dimensions match paper size at 96 DPI
- **Multi-page support** — auto page count, page dividers, add/remove buttons
- **Header/footer preview** — rendered in iframes above/below the editable area
- **Template variable blocks** — insertable `{{ variable }}` tokens
- **Save/load** — serializes GrapesJS project data for DB persistence
- **PDF export** — extracts HTML/CSS and sends to server for ChromicPDF generation
- **Media selector** — integrates with PhoenixKit Storage for image insertion

### Hooks registered

| Hook | Used by |
|---|---|
| `GrapesJSTemplateEditor` | Template editor page |
| `GrapesJSDocumentEditor` | Document editor page |
| `GrapesJSHFEditor` | Header/footer editor page |

## Navigation (Paths Module)

All paths go through `PhoenixKit.Utils.Routes.path/1` via the centralized `Paths` module:

```elixir
alias PhoenixKitDocumentCreator.Paths

Paths.index()                  # /admin/document-creator
Paths.template_new()           # /admin/document-creator/templates/new
Paths.template_edit(uuid)      # /admin/document-creator/templates/:uuid/edit
Paths.document_edit(uuid)      # /admin/document-creator/documents/:uuid/edit
Paths.headers()                # /admin/document-creator/headers
Paths.header_new()             # /admin/document-creator/headers/new
Paths.header_edit(uuid)        # /admin/document-creator/headers/:uuid/edit
Paths.footers()                # /admin/document-creator/footers
Paths.footer_new()             # /admin/document-creator/footers/new
Paths.footer_edit(uuid)        # /admin/document-creator/footers/:uuid/edit
Paths.testing()                # /admin/document-creator/testing
Paths.testing_pdfme()          # /admin/document-creator/testing/pdfme
Paths.testing_tiptap()         # /admin/document-creator/testing/tiptap
```

## Shared Components

The module demonstrates component reuse across multiple LiveViews:

| Component | File | Used by |
|---|---|---|
| `EditorScripts` | `web/components/editor_scripts.ex` | All editor pages |
| `EditorPanel` | `web/components/editor_panel.ex` | Template and document editors |
| `CreateDocumentModal` | `web/components/create_document_modal.ex` | Documents landing page |

### EditorPanel

Shared GrapesJS editor container used by both the template and document editors. Parameterized via attrs:

```elixir
import PhoenixKitDocumentCreator.Web.Components.EditorPanel

<.editor_panel
  id="template"
  hook="GrapesJSTemplateEditor"
  save_event="save_template"
  template_vars={true}
/>
```

### CreateDocumentModal

Multi-step modal for creating documents:

1. **Choose** — blank document or pick a published template
2. **Variables** — fill in template variable values (if template selected)
3. **Create** — renders variables via Solid and redirects to document editor

## Migration System

Uses PhoenixKit's versioned migration pattern. Version tracked via SQL comment on the `phoenix_kit_doc_headers_footers` table.

| Version | Changes |
|---|---|
| V01 | Initial tables: `headers_footers` (paired header/footer columns), `templates` (single `header_footer_uuid` FK), `documents` (single `header_footer_uuid` FK) |
| V02 | Refactor headers/footers from paired columns to type-discriminated records (`type` = `"header"` or `"footer"`). Replace single `header_footer_uuid` FK with separate `header_uuid` + `footer_uuid` on templates and documents. |
| V03 | Add `thumbnail` text column to templates and documents for page preview data URIs |

### Coordinator

```elixir
PhoenixKitDocumentCreator.Migration.current_version()         # => 3
PhoenixKitDocumentCreator.Migration.migrated_version()         # Reads DB version
PhoenixKitDocumentCreator.Migration.up()                       # Run pending migrations
PhoenixKitDocumentCreator.Migration.down()                     # Roll back all
PhoenixKitDocumentCreator.Migration.migrated_version_runtime() # Safe for Mix tasks
```

### Upgrades

When users update the dep and run `mix phoenix_kit.update`, PhoenixKit auto-detects the migration module, compares versions, and runs only the new migrations.

## PhoenixKit Module Integration

### Behaviour callbacks

| Callback | Value |
|---|---|
| `module_key` | `"document_creator"` |
| `module_name` | `"Document Creator"` |
| `version` | `"0.2.0"` |
| `permission_metadata` | Key: `"document_creator"`, icon: `"hero-document-text"` |
| `migration_module` | `PhoenixKitDocumentCreator.Migration` |
| `children` | `[ChromeSupervisor]` (when ChromicPDF available) |
| `admin_tabs` | 10 base + 3 conditional testing tabs |

### Permission

The module registers `"document_creator"` as a permission key. Owner and Admin roles get access automatically. Custom roles must be granted access via Admin > Roles.

## Project Structure

```
lib/
  phoenix_kit_document_creator.ex              # Main module (behaviour callbacks)
  phoenix_kit_document_creator/
    chrome_supervisor.ex                       # Lazy Chrome startup
    document_format.ex                         # Editor-agnostic document format
    documents.ex                               # Context: templates, documents, headers/footers
    paths.ex                                   # Centralized URL path helpers
    variable.ex                                # Variable extraction and type guessing
    migration.ex                               # Versioned migration coordinator
    schemas/
      document.ex                              # Document schema
      header_footer.ex                         # Header/footer schema (type discriminator)
      template.ex                              # Template schema (with slug auto-gen)
    migration/postgres/
      v01.ex                                   # Initial tables
      v02.ex                                   # Split headers/footers
      v03.ex                                   # Add thumbnails
    web/
      documents_live.ex                        # Landing page (templates + documents tabs)
      template_editor_live.ex                  # GrapesJS template editor
      document_editor_live.ex                  # GrapesJS document editor
      header_footer_live.ex                    # List page for headers/footers
      header_footer_editor_live.ex             # GrapesJS header/footer editor
      editor_pdf_helpers.ex                    # PDF generation via ChromicPDF
      testing_live.ex                          # Testing hub (behind config)
      editor_pdfme_test_live.ex                # pdfme editor test
      editor_tiptap_test_live.ex               # TipTap editor test
      components/
        editor_scripts.ex                      # Base64-encoded JS loader
        editor_hooks.js                        # GrapesJS hooks (~1500 lines)
        editor_panel.ex                        # Shared editor UI component
        create_document_modal.ex               # Multi-step creation modal
  mix/tasks/
    phoenix_kit_document_creator.install.ex     # Installation task
```

## Development

### Code quality

```bash
mix format
mix credo --strict
mix dialyzer
```

### Recompiling JS changes

After editing `editor_hooks.js`:

```bash
# From parent app directory
mix deps.compile phoenix_kit_document_creator --force
# Then restart the Phoenix server
```

The `@external_resource` annotation ensures Mix tracks the JS file. A content hash is embedded in the HTML so the bootstrapper re-executes on navigation when the JS has changed.

---

## Open-Source Tools Reference

### PDF Generation Libraries

| Tool | Hex Package | Description | Status |
|------|------------|-------------|--------|
| **ChromicPDF** | `chromic_pdf` | HTML→PDF via Chrome DevTools protocol. Used by this module. | Active |
| **PrawnEx** | `prawn_ex` | Pure Elixir PDF gen inspired by Ruby's Prawn. | New |
| **Mudbrick** | `mudbrick` | PDF 2.0 generator. Pure functional, OpenType fonts. | Active |
| **pdf** | `pdf` | Pure Elixir PDF. Manual coordinate positioning. | Maintained |

### Typst-Based (alternative approach)

| Tool | Hex Package | Description | Status |
|------|------------|-------------|--------|
| **typst** | `typst` | Rustler NIF bindings. ~5-30ms per PDF. 1.5M+/day documented. | Active |
| **Imprintor** | `imprintor` | Typst via Rustler NIF. JSON data binding. | Active |

### Template Engines

| Tool | Hex Package | Description | Status |
|------|------------|-------------|--------|
| **Solid** | `solid` | Liquid template engine. `{{ variable }}` syntax. Used by this module. | Active |
| **Carbone** | Docker | DOCX/ODT templates + JSON → PDF/DOCX. Self-hosted. | Active |

### Rich Text Editors

| Tool | Integration | Description | Status |
|------|------------|-------------|--------|
| **GrapesJS** | CDN + JS hook | Drag-and-drop page builder. Used by this module. | Active |
| **TipTap** | JS hook | Headless editor on ProseMirror. Good LiveView fit. | Active |
| **CKEditor 5** | `ckeditor5_phoenix` | Feature-rich. GPL/commercial license. | Active |

## License

MIT
