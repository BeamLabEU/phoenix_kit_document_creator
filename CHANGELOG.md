## 0.2.0 - 2026-03-25

### Fixed
- Fix XSS/CSS injection vulnerabilities in editor rendering
- Remove module-level migrations (host app manages migrations)
- Fix editor canvas styles via data URI for consistent rendering
- Fix header/footer PDF rendering: sanitize CSS, fix positioning, remove artifacts
- Fix PDF header/footer heights and paper size filtering

### Added
- Add PR review documentation structure (`dev_docs/pull_requests/`)
- Add level 2 integration tests with test repo and SQL Sandbox
- Add editor panel component with thumbnail previews
- Add schema and PDF helper unit tests
- Add baking pattern: header/footer content copied into documents at creation time
- Add full-page preview in header/footer editor with paper size selector
- Add versioned migration framework (V01-V04)
- Add centralized path helpers module

### Changed
- Redesign header/footer editor with full-page preview
- Replace listing tables with page preview cards
- Simplify status system

## 0.1.0 - 2026-03-24

### Added
- Extract Document Creator from PhoenixKit into standalone `phoenix_kit_document_creator` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add `Template` schema (HTML, CSS, GrapesJS native data, paper size, slug)
- Add `Document` schema (rendered HTML/CSS, baked header/footer content)
- Add `HeaderFooter` schema (type discriminator: header/footer)
- Add GrapesJS drag-and-drop template editor with LiveView hooks
- Add document editor for post-creation editing
- Add ChromicPDF integration for PDF export with lazy Chrome startup
- Add Solid (Liquid syntax) template variable substitution
- Add admin LiveViews: template editor, document editor, listings, header/footer editor
- Add drag/resize boundary constraints and coordinate offset fixes
- Add GrapesJS panel customization, theme sync, and canvas centering
