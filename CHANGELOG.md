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
