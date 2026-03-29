# AGENTS.md — PhoenixKit Document Creator

## Project Overview

Elixir library (Hex package) that adds a visual document template editor and PDF generation to PhoenixKit apps. Uses GrapesJS for drag-and-drop editing, Solid (Liquid syntax) for template variables, and ChromicPDF (headless Chrome) for PDF export.

## Tech Stack

- **Language**: Elixir ~> 1.15
- **Framework**: Phoenix LiveView ~> 1.0
- **Database**: PostgreSQL (via Ecto through PhoenixKit's repo)
- **Editor**: GrapesJS (vendored in `priv/static/vendor/grapesjs/`)
- **PDF**: ChromicPDF ~> 1.17 (headless Chrome)
- **Templates**: Solid ~> 1.2 (Liquid syntax for `{{ variable }}` substitution)
- **Parent**: PhoenixKit (provides Module behaviour, Settings API, admin layout, Ecto repo)

## Project Structure

```
lib/
  phoenix_kit_document_creator.ex          # Main module — PhoenixKit.Module behaviour, tab registration, routes
  phoenix_kit_document_creator/
    documents.ex                           # Context module — CRUD for templates, documents, headers/footers
    chrome_supervisor.ex                   # Lazy ChromicPDF startup (starts Chrome only on first PDF export)
    document_format.ex                     # JSON interchange format (mostly unused — legacy from research spike)
    variable.ex                            # Extract {{ variables }} from HTML content
    paths.ex                               # Centralized route path helpers
    migration.ex                           # Versioned migration framework (V01–V04)
    migration/postgres/v01.ex–v04.ex       # Individual migration versions
    schemas/
      template.ex                          # Template schema (HTML, CSS, GrapesJS native data, paper size, slug)
      document.ex                          # Document schema (rendered HTML/CSS, baked header/footer content)
      header_footer.ex                     # HeaderFooter schema (type discriminator: "header" | "footer")
    web/
      template_editor_live.ex              # LiveView — GrapesJS template editor with header/footer assignment
      document_editor_live.ex              # LiveView — GrapesJS document editor (post-creation editing)
      documents_live.ex                    # LiveView — document listing with thumbnail preview cards
      header_footer_editor_live.ex         # LiveView — GrapesJS header/footer editor with full-page preview
      header_footer_live.ex                # LiveView — header/footer listing page
      editor_pdf_helpers.ex                # PDF generation, thumbnail generation, CSS sanitization
      testing_live.ex                      # Testing/comparison overview page (behind :testing_editors flag)
      editor_tiptap_test_live.ex           # TipTap test editor (behind :testing_editors flag)
      editor_pdfme_test_live.ex            # pdfme test editor (behind :testing_editors flag)
      components/
        editor_hooks.js                    # GrapesJS JavaScript hooks for LiveView (base64-embedded at compile time)
        editor_panel.ex                    # Shared editor panel component (data-attribute config for JS hooks)
        editor_scripts.ex                  # Script/CSS tags for GrapesJS (CDN + vendored fallback)
        create_document_modal.ex           # Modal for creating documents from templates with variable inputs

test/
  test_helper.exs                          # Smart DB detection — excludes integration tests when DB unavailable
  support/
    test_repo.ex                           # Ecto repo for tests
    data_case.ex                           # ExUnit case template with SQL Sandbox
  schemas/                                 # Unit tests for schema changesets (no DB needed)
  integration/documents_test.exs           # Integration tests — full CRUD + template→document baking
  editor_pdf_helpers_test.exs              # Unit tests for thumbnail/PDF helpers
  phoenix_kit_document_creator_test.exs    # Unit tests for main module, variable extraction
```

## Key Architectural Decisions

- **Baking pattern**: When a document is created from a template, header/footer HTML, CSS, and height are copied directly into the document record. Documents are fully self-contained — deleting templates or headers/footers won't break existing documents.
- **Lazy Chrome**: ChromicPDF starts only on first PDF export, not at app boot. Managed by `ChromeSupervisor`.
- **Versioned migrations**: V01–V04 with auto-discovery. Host app runs `mix phoenix_kit_document_creator.install` to generate migration, then `mix ecto.migrate`.
- **No own Ecto repo**: Uses the host app's repo via `PhoenixKit.repo()`.
- **GrapesJS vendored + CDN**: JS hooks are base64-embedded at compile time from `editor_hooks.js`. GrapesJS itself loads from vendored files with CDN fallback.

## Running Tests

```bash
# Unit tests only (no database needed)
mix test --exclude integration

# All tests (requires PostgreSQL)
createdb phoenix_kit_document_creator_test
mix test
```

## Common Tasks

- **Adding a new migration version**: Create `lib/phoenix_kit_document_creator/migration/postgres/vXX.ex`, update `migration.ex` to include the new version.
- **Adding editor blocks**: Edit `editor_hooks.js` — blocks are defined in the `initBlocks` function.
- **Changing PDF rendering**: `editor_pdf_helpers.ex` handles all ChromicPDF interaction, CSS sanitization, and header/footer wrapping.
- **Adding new admin tabs**: Register in `phoenix_kit_document_creator.ex` `tabs/0` function.

## Versioning & Releases

Version is tracked in three places — all must match:
1. `mix.exs` — `@version`
2. `lib/phoenix_kit_document_creator.ex` — `def version, do: "x.y.z"`
3. `test/phoenix_kit_document_creator_test.exs` — version compliance test

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.0
git push origin 0.1.0
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.0 \
  --title "0.1.0 - 2026-03-24" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in all three locations above
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

## Known Issues to Address

- `DocumentFormat` module is mostly dead code from the research spike
- `humanize/1` and `extract_variables` logic duplicated across multiple modules
