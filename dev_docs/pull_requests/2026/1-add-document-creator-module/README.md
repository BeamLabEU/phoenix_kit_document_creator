# PR #1: Add Document Creator module for PhoenixKit

**Author**: @mdon (Max Don)
**Reviewer**: @claude
**Status**: ✅ Merged
**Commit**: `ec249b5..9900de2` (20 commits)
**Date**: 2026-03-23
**PR**: https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/1

## Goal

Add a complete visual document creation system to PhoenixKit — drag-and-drop template editor (GrapesJS), template variables with Liquid syntax, reusable headers/footers, and PDF export via ChromicPDF. This is the initial implementation following a research spike that evaluated 7 WYSIWYG editors and settled on GrapesJS.

## What Was Changed

This is the initial feature PR — the entire codebase was added. +8,977 lines across 46 files.

### Core Modules

| File | Purpose |
|------|---------|
| `lib/phoenix_kit_document_creator.ex` | Main module — PhoenixKit.Module behaviour, tab registration, routes |
| `lib/phoenix_kit_document_creator/documents.ex` | Context — CRUD for templates, documents, headers/footers |
| `lib/phoenix_kit_document_creator/chrome_supervisor.ex` | Lazy ChromicPDF startup |
| `lib/phoenix_kit_document_creator/variable.ex` | Extract `{{ variables }}` from HTML |
| `lib/phoenix_kit_document_creator/paths.ex` | Centralized route path helpers |
| `lib/phoenix_kit_document_creator/document_format.ex` | JSON interchange format (legacy from spike) |

### Schemas

| File | Purpose |
|------|---------|
| `schemas/template.ex` | HTML, CSS, GrapesJS native data, paper size, slug |
| `schemas/document.ex` | Rendered HTML/CSS, baked header/footer content |
| `schemas/header_footer.ex` | Type discriminator: "header" or "footer" |

### LiveViews

| File | Purpose |
|------|---------|
| `web/template_editor_live.ex` | GrapesJS template editor with header/footer assignment |
| `web/document_editor_live.ex` | GrapesJS document editor (post-creation editing) |
| `web/documents_live.ex` | Document listing with thumbnail preview cards |
| `web/header_footer_editor_live.ex` | Header/footer editor with full-page preview |
| `web/header_footer_live.ex` | Header/footer listing page |
| `web/editor_pdf_helpers.ex` | PDF generation, thumbnails, CSS sanitization |

### Migrations

4 versioned PostgreSQL migrations (V01–V04):
- **V01**: Core tables (templates, documents, headers_footers)
- **V02**: Split header/footer into independent entities
- **V03**: Thumbnail columns
- **V04**: Bake header/footer content into documents (drop FKs)

### Tests

115 tests (94 unit + 21 integration):
- Schema changeset validations
- EditorPdfHelpers thumbnail/CSS tests
- Variable extraction tests
- Full CRUD integration tests with SQL Sandbox
- Template-to-document baking with survival tests

## Implementation Details

### Baking Pattern (V04)

When a document is created from a template, header/footer HTML, CSS, and height are copied directly into the document record. Documents are fully self-contained — deleting templates, headers, or footers won't break existing documents. This was a deliberate architectural choice to avoid FK coupling.

### Lazy Chrome Startup

ChromicPDF is started on first PDF export via `ChromeSupervisor`, not at app boot. This keeps things lightweight when the module is enabled but PDF generation isn't actively used.

### GrapesJS Integration

- JS hooks are base64-embedded at compile time from `editor_hooks.js`
- GrapesJS vendored locally with CDN fallback
- Theme synced with DaisyUI via CSS custom properties
- Drag/resize boundary constraints keep elements within page bounds

### Template Variables

Variables like `{{ client_name }}` are auto-detected via regex, rendered via Solid (Liquid engine), with a regex fallback if Solid fails.

## Migration Notes

For parent applications:

```bash
mix deps.get
mix phoenix_kit_document_creator.install   # Creates migration file
mix ecto.migrate                            # Creates database tables
```

Requires Chrome/Chromium for PDF generation. Module loads without it but PDF export returns an error.

## Related

- GrapesJS: https://grapesjs.com/
- ChromicPDF: https://hex.pm/packages/chromic_pdf
- Solid (Liquid): https://hex.pm/packages/solid
- Review: [CLAUDE_REVIEW.md](CLAUDE_REVIEW.md)
