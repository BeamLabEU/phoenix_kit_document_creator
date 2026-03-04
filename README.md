# Document Creator

PDF generation testing module for [PhoenixKit](https://hex.pm/packages/phoenix_kit). Compare two approaches side-by-side before committing to one for production.

## Two Approaches

| | ChromicPDF | Typst |
|---|---|---|
| **How** | HTML + CSS → headless Chrome → PDF | Typst markup → Rust NIF → PDF |
| **Speed** | ~200-500ms | ~5-30ms |
| **Quality** | Browser rendering | Professional typesetting |
| **Deps** | Chrome/Chromium on system | Precompiled NIF (no toolchain) |
| **PDF/A** | Yes (via Ghostscript) | Yes (native) |
| **Best for** | Reusing HTML/CSS skills | High volume, pixel-perfect output |
| **Editing story** | TipTap/ProseMirror (rich HTML editors) | Form-based or code editor |

## Setup

1. Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_document_creator, path: "../phoenix_kit_document_creator"}
```

2. Fetch deps:

```bash
mix deps.get
```

3. Start your app, go to Admin > Modules, enable "Document Creator".

### Prerequisites

- **ChromicPDF test**: Chrome or Chromium installed on the system
- **Typst test**: No extra install — uses precompiled Rust NIFs

## Pages

- **Overview** — Environment check, approach comparison, tools reference
- **ChromicPDF Test** — HTML textarea → generate PDF → download
- **Typst Test** — Fill contract template variables → generate PDF → download

## Architecture Notes

ChromicPDF is started **lazily** via `PhoenixKitDocumentCreator.ChromeSupervisor` — Chrome only launches when you actually generate a PDF, not at app boot. This keeps things lightweight when the module is enabled but not actively used.

The `chromic_pdf` dependency is marked `optional: true`, so the module compiles and loads even without Chrome installed. The overview page shows which tools are available.

---

## Open-Source Tools Reference

### PDF Generation Libraries

| Tool | Hex Package | Description | Status |
|------|------------|-------------|--------|
| **ChromicPDF** | `chromic_pdf` | HTML→PDF via Chrome DevTools protocol. Community standard. 474 GitHub stars. | Active |
| **PrawnEx** | `prawn_ex` | Pure Elixir PDF gen inspired by Ruby's Prawn. Tables, charts, images. | New |
| **Mudbrick** | `mudbrick` | PDF 2.0 generator. Pure functional, OpenType fonts. | Active |
| **pdf** | `pdf` | Pure Elixir PDF. Manual coordinate positioning. | Maintained |
| **pdf_generator** | `pdf_generator` | wkhtmltopdf wrapper. Engine is deprecated upstream. | Legacy |

### Typst-Based

| Tool | Hex Package | Description | Status |
|------|------------|-------------|--------|
| **typst** | `typst` | Rustler NIF bindings. EEx-style template formatting. | Active |
| **Imprintor** | `imprintor` | Typst via Rustler NIF. JSON data binding. | Active |
| **ExTypst** | `ex_typst` | Earlier Typst bindings. Superseded by `typst` package. | Legacy |

### Template Engines

| Tool | Hex Package | Description | Status |
|------|------------|-------------|--------|
| **Solid** | `solid` | Liquid template engine for Elixir. `{{ variable }}` syntax. | Active |
| **Carbone** | Docker | DOCX/ODT templates + JSON → PDF/DOCX. Self-hosted free. | Active |
| **docxtemplater** | npm | JS DOCX template filling. `{placeholder}` syntax. | Active |

### External Services / Microservices

| Tool | Package | Description | Status |
|------|---------|-------------|--------|
| **Gotenberg** | `gotenberg_elixir` | Docker API: Chromium + LibreOffice for doc conversion. | Active |
| **DocuSeal** | Self-hosted | Open-source e-signature platform. AGPL-3.0. REST API. | Active |
| **Documenso** | Self-hosted | Open-source DocuSign alternative. AGPL-3.0. | Active |
| **Wraft** | Self-hosted | Document lifecycle platform built in Elixir. AGPL-3.0. | Active |

### Rich Text Editors (for future editing features)

| Tool | Integration | Description | Status |
|------|------------|-------------|--------|
| **TipTap** | JS hook | Headless editor on ProseMirror. 100+ extensions. MIT. Best LiveView fit. | Active |
| **CKEditor 5** | `ckeditor5_phoenix` | Feature-rich. GPL/commercial license. Phoenix package exists. | Active |
| **Quill.js** | JS hook | Simpler editor. Good for basic rich text, less extensible. | Maintained |

---

## Production Architecture Recommendations

For a production contract/agreement system:

### If you choose ChromicPDF (HTML path):
1. **Templates**: Store as HTML with merge fields (`{{ client_name }}`) in PostgreSQL
2. **Editing**: TipTap rich text editor via LiveView JS hook
3. **Variables**: Solid (Liquid) for template rendering
4. **Export**: ChromicPDF → `send_download/3`
5. **Async**: Oban worker for large/batch generation

### If you choose Typst:
1. **Templates**: `.typ` files stored in DB with EEx bindings
2. **Editing**: Structured form UI for variables + Monaco editor for power users
3. **Preview**: typst.ts WASM for browser-side SVG preview
4. **Export**: `Typst.render_to_pdf/2` NIF → `send_download/3`
5. **Performance**: 1.5M+ PDFs/day is documented in production

### Hybrid approach:
- Edit documents in browser with TipTap (HTML)
- Export via Typst for higher quality output
- Requires HTML→Typst conversion layer (more complexity)
