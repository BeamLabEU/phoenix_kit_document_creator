## 0.2.3 - 2026-04-06

### Changed
- Migrate Google OAuth credentials to centralized PhoenixKit.Integrations system
- Remove duplicate OAuth code (authorization, exchange, refresh, userinfo)
- Simplify settings LiveView — OAuth flow now handled by Integrations core
- Declare `required_integrations: ["google"]`
- Update dependencies to latest versions

## 0.2.2 - 2026-04-02

### Added
- Add `css_sources/0` callback for Tailwind CSS scanning of module components

### Changed
- Upgrade dependencies

## 0.2.1 - 2026-03-30

### Added
- Add soft delete for documents and templates — files move to deleted folders instead of permanent removal
- Add configurable folder paths and names with Google Drive folder browser
- Add `ensure_folder_path/2` — walks nested Drive paths, creating folders as needed
- Add `move_file/2` to GoogleDocsClient (Drive API PATCH with addParents/removeParents)
- Add `list_subfolders/1` for the Drive folder browser
- Add `validate_file_id/1` to prevent URL path injection in Drive API calls
- Add `get_folder_config/0` for reading folder path + name settings
- Add loading spinner for thumbnail placeholders
- Add delete button (trash icon) on card and list views with confirmation dialog
- Add flash feedback on successful delete
- Add folder browser modal with breadcrumb navigation to settings page
- Add tests for `validate_file_id/1` and `move_file/2` input validation

### Changed
- Parallelize folder discovery with `Task.async` + `Task.await_many` (was sequential)
- Make folder browser loading async via `Task.start` (no longer blocks LiveView)
- Whitelist `browser_field` values to prevent atom exhaustion
- Guard `browser_back` against invalid index
- Strip charset from content-type header in `extract_content_type`
- Update modal template cards to match main page card styling (border, shadow, flex layout)

### Fixed
- Fix `FunctionClauseError` in thumbnail loading — handle map header format from Req >= 0.5

### Removed
- Remove orphaned `editor_scripts.ex` (dead code from GrapesJS removal)

## 0.2.0 - 2026-03-29

### Changed
- Replace local editor architecture (GrapesJS, TipTap, pdfme) with Google Docs API
- Replace ChromicPDF/Gotenberg PDF generation with Google Drive API export
- Rewrite `Documents` context for Google Drive operations (list, create, copy, variable substitution)
- Simplify admin tabs from 13 to 3 (parent + documents + templates)
- Simplify `Paths` module to 4 helpers (index, templates, documents, settings)
- Rewrite `CreateDocumentModal` for Google Docs workflow

### Added
- Add `GoogleDocsClient` — OAuth 2.0, Google Docs API, Google Drive API
- Add `GoogleOAuthSettingsLive` — admin settings page for connecting Google account
- Add `google_doc_id` column to templates, documents, and headers/footers (PhoenixKit V88 migration)
- Add unit tests for `GoogleDocsClient`

### Removed
- Remove GrapesJS editor and all JS hooks (`editor_hooks.js`, ~1500 lines)
- Remove `TemplateEditorLive`, `DocumentEditorLive`, `HeaderFooterEditorLive` LiveViews
- Remove `HeaderFooterLive` listing page
- Remove `EditorPanel` and `EditorScripts` components
- Remove `EditorPdfHelpers` (ChromicPDF/Gotenberg PDF generation)
- Remove `DocumentFormat` module (legacy JSON interchange format)
- Remove `TestingLive`, `EditorPdfmeTestLive`, `EditorTiptapTestLive` (editor comparison pages)
- Remove `chromic_pdf` and `solid` dependencies

## 0.1.2 - 2026-03-25

### Fixed
- Fix all credo warnings (alias ordering, Enum.map_join, cyclomatic complexity)
- Fix all dialyzer warnings (Solid.render pattern match, dead code branches)
- Flatten nesting in ChromeSupervisor using `with`

### Removed
- Remove obsolete `mix phoenix_kit_document_creator.install` task

### Added
- Add PDF generation options research document

## 0.1.1 - 2026-03-25

### Added
- Add MIT LICENSE file
- Add CHANGELOG.md
- Add `@source_url` and GitHub links to mix.exs package metadata
- Add `precommit` mix alias (compile + quality)
- Add PR documentation template
- Add Versioning & Releases section to AGENTS.md

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
