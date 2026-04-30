## 0.2.8 - 2026-04-30

### Added
- `PhoenixKitDocumentCreator.Errors` — atom dispatcher with one literal `gettext/1` clause per atom (28 atoms). Centralises error translation for the public API; consumers call `Errors.message(reason)` at the UI/API boundary. Same shape as `PhoenixKitSync.Errors` and `PhoenixKitLocations.Errors`. Documented in README.
- SSRF guard on `GoogleDocsClient.fetch_thumbnail_image/1` — `validate_thumbnail_url/1` allowlists `*.googleusercontent.com` / `*.google.com` host suffixes; rejects metadata service (169.254.169.254), loopback, RFC1918, look-alike hosts, non-`http(s)` schemes. Pinned with 8 unit tests.
- Redirect block on the thumbnail fetch — `Req.get/2` is called with `redirect: false` so a 302 from a Google CDN host to an internal IP can't bypass the SSRF allowlist. Pinned with a `Req.Test`-stubbed end-to-end test.
- LiveView test infrastructure: `Test.Endpoint`, `Test.Router`, `Test.Layouts` (with stable flash IDs), `LiveCase`, on-mount hooks, `ActivityLogAssertions` helper, `Test.StubIntegrations` ETS-backed integrations stub.
- `phx-disable-with` on every async + destructive button (refresh, create, modal create, file actions, export PDF, restore, delete, save folder settings, unfiled actions).
- AGENTS.md "What This Module Does NOT Have (by design)" section anchoring deliberate non-features.

### Changed
- **(potentially breaking)** `GoogleDocsClient` and `DriveWalker` now return tagged atoms (`:folder_search_failed`, `:create_folder_failed`, `:create_document_failed`, `:move_failed`, `:get_file_parents_failed`, `:copy_failed`, `:pdf_export_failed`, `:thumbnail_link_failed`, `:thumbnail_fetch_failed`, `:list_files_failed`) on the error branch instead of raw `{:error, "Foo failed: #{inspect(body)}"}` strings. Consumers matching on the string form must switch to atoms (or call `Errors.message/1` to translate).
- `Document.creation_changeset/2`, `Document.sync_changeset/2`, and `Template.sync_changeset/2` now `validate_length(:name, max: 255)`. Over-long names return a clean `{:error, %Ecto.Changeset{}}` instead of raising `Ecto.Adapters.SQL` exceptions.
- `Documents.fetch_thumbnails_async/2` runs under a single supervised parent task in `PhoenixKit.TaskSupervisor` with `Task.async_stream/3` `max_concurrency: 8`. Pre-fix opening a 500-file folder fired 500 unsupervised `Task.start/1` calls.
- `DocumentsLive.mount/3` subscribes to `"document_creator:files"` BEFORE the initial DB read, closing a race window where a `:files_changed` broadcast could be dropped between read and subscribe.
- Activity logging now lands a `db_pending: true` audit row on the error branch of every user-driven mutation (`create_template`, `create_document`, `delete_*`, `restore_*`, `export_pdf`, `set_correct_location`, `create_document_from_template`). Pre-fix a Drive outage erased admin clicks from the audit feed.
- `Task.start/1` → `Task.start_link/1` in `:sync_from_drive` and `:load_drive_folders` LV handlers — orphan tasks now die with the LV instead of running unsupervised after the tab closes.
- `try/rescue` around the `:perform_file_action` backend call so a Drive API raise (econnrefused, HTTP timeout) doesn't crash the LV and wedge `pending_files` on remount.
- Drive API error responses are now logged at 500-char truncation via `log_drive_error/2` instead of being serialised in full into the error tuple.
- `discover_folders/0` timeout cleanup now uses `catch :exit, _` instead of `rescue` — `Task.await_many/2` signals timeouts via `exit/1`, so the previous `rescue` clause never fired and the LV crashed instead of hitting the nil fallback.
- `extract_content_type/1` logs at `:debug` when a Drive thumbnail's content-type falls outside the `~w(image/png image/jpeg image/webp image/gif)` allowlist and is downgraded to `image/png`.
- `handle_info` catch-all in both LiveViews promoted from silent drop to `Logger.debug` so stray PubSub / fixture messages stay observable when debugging.

### Fixed
- Removed deprecated `Variable.extract_from_html/1` (was `@doc false` + `@deprecated` since the Google Docs pivot).
- `enabled?/0` now adds `catch :exit, _ -> false` for sandbox-shutdown resilience.
- README: new `PhoenixKitDocumentCreator.Errors` section listing the error atoms emitted by the public API and showing the canonical translate-at-the-boundary pattern.

### Tests
- 161 → 376 tests, 0 failures, 10/10 stable runs.
- Production coverage: ~52% → **77.92%** via built-in `mix test --cover` (no Mox / no excoveralls). `mix.exs` adds `test_coverage: [ignore_modules: [...]]` so the percentage reports production-only code.

## 0.2.7 - 2026-04-22

### Added
- `GoogleDocsClient.DriveWalker` module — paginated `list_files/1` / `list_folders/1` and recursive `walk_tree/2` (BFS, `pageSize: 1000`, `nextPageToken` looping, batched `'a' in parents or …` queries chunked at 40 IDs per request). Both folder discovery and file listing now cost `O(ceil(N / 40))` Drive calls per BFS level instead of `O(N)` sequential list calls.
- `Documents.register_existing_document/2` and `register_existing_template/2` — DB-only upsert for Drive files the caller has already created (e.g. consumers that organise files into `documents/order-N/sub-M/`). Validates `google_doc_id` via `validate_file_id/1`, validates `template_uuid` via `foreign_key_constraint`, uses `maybe_put/3` so re-registration without optional fields preserves existing values. Opts: `:actor_uuid` (activity log), `:emit_pubsub` (default `true`).
- `Documents.pubsub_topic/0` and `Documents.broadcast_files_changed/0` — single source of truth for the `"document_creator:files"` topic; bulk callers can pass `emit_pubsub: false` and broadcast once at the end.
- `create_document_from_template/3`: new `:parent_folder_id` and `:path` options for placing documents in consumer-managed subfolders.
- `foreign_key_constraint(:template_uuid)` on `Document` changeset — invalid template UUIDs now return a changeset error instead of raising.
- Catch-all `handle_info/2` in `GoogleOAuthSettingsLive` to prevent crashes on unexpected messages (Task supervisor signals, stray PubSub traffic).

### Changed
- `sync_from_drive/0` recursively walks both managed trees and upserts every Google Doc found (including those nested in subfolders) with its actual parent `folder_id` and resolved `path`.
- `classify_by_location/5` accepts a `MapSet` of enumerated folder IDs so files in descendant subfolders stay `:published` instead of being reclassified as `:unfiled`.
- Reconcile drops the implicit "file must be in managed root" rule — any descendant of a managed folder is treated as `:published`.
- `list_folder_files/1` and `list_subfolders/1` on `GoogleDocsClient` now delegate to `DriveWalker` — full pagination instead of the previous silent 100-item cap.
- Narrowed `Documents.default_managed/2` rescue from bare `_` to a targeted set (`ArgumentError`, `KeyError`, `MatchError`, `BadMapError`, `DBConnection.ConnectionError`, `Postgrex.Error`) so future `FunctionClauseError` / `RuntimeError` bugs propagate instead of being silently swallowed.

### Fixed
- Silent data loss past 100 items in `list_folder_files/1` / `list_subfolders/1` — both now fully paginate.
- `test_helper.exs` no longer crashes on module load when `psql` is missing from `PATH` (sandboxes / minimal CI images); degrades to the connect-attempt branch instead.
- `test_helper.exs` PubSub supervisor bootstrap now raises on unexpected errors instead of silently ignoring them.

## 0.2.6 - 2026-04-15

### Added
- Trash tab in DocumentsLive with Active/Trash status toggle (auto-hidden when empty)
- Restore from trash — `restore_template/2`, `restore_document/2`, and `list_trashed_*_from_db/0`
- Pending spinner overlay on cards during async delete/restore (layout-stable)
- `phx-disable-with` on New Template / New Document buttons

### Changed
- Sort document/template lists by `inserted_at DESC` (workaround; see AGENTS.md TODO for `drive_modified_at`)
- Remove delete confirmation popup — soft delete is recoverable from Trash
- Refactor delete flow into data-driven `action_spec/2` shared with restore

### Fixed
- PDF download: anchor now appended to DOM before `.click()` (fixes Firefox)
- Catch-all `handle_info/2` to avoid crashes on unexpected messages

## 0.2.5 - 2026-04-12

### Fixed
- Add routing anti-pattern warning to AGENTS.md

## 0.2.4 - 2026-04-09

### Fixed
- Fix 3 dialyzer errors (invalid contract, pattern match issues)
- Fix sync_from_drive error swallowing (now logs reason)
- Fix schema field access (direct instead of Map.get)

### Changed
- Refactor create_document: extract persist_created_document/5
- Remove dead list_templates/list_documents (replaced by DB versions)
- Graceful DB insert failure (Drive doc still returned, sync picks it up)

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
