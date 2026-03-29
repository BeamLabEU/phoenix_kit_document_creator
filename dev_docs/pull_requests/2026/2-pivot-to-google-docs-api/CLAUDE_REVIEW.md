# PR #2: Pivot Document Creator from local editors to Google Docs API

**Author**: @mdon
**Reviewer**: @claude (deep review)
**Status**: Merged
**Commit**: `b10478c` (squashed from 4 commits)
**Date**: 2026-03-29

## Goal

Replace the entire local editor stack (GrapesJS, TipTap, pdfme, ChromicPDF/Gotenberg) with Google Docs for editing and Google Drive for storage. Templates and documents now live entirely in Google Drive, with OAuth 2.0 connecting a Google account. This dramatically simplifies the architecture: no JS editors, no headless Chrome, no local PDF pipeline.

## What Was Changed

### Files Added

| File | Purpose |
|------|---------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | Google Docs + Drive API client with OAuth 2.0, auto-refresh |
| `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex` | Admin settings page for OAuth credential setup and account connection |
| `test/google_docs_client_test.exs` | Unit tests for GoogleDocsClient (pure functions + interface) |

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator.ex` | Updated moduledoc, version bump to 0.2.0, settings_tabs callback added |
| `lib/phoenix_kit_document_creator/documents.ex` | Rewritten: CRUD now wraps GoogleDocsClient instead of Ecto repo |
| `lib/phoenix_kit_document_creator/paths.ex` | Simplified: removed editor/header-footer paths, kept index/templates/documents/settings |
| `lib/phoenix_kit_document_creator/schemas/template.ex` | Added `google_doc_id` field |
| `lib/phoenix_kit_document_creator/schemas/document.ex` | Added `google_doc_id` field |
| `lib/phoenix_kit_document_creator/schemas/header_footer.ex` | Added `google_doc_id` field |
| `lib/phoenix_kit_document_creator/web/documents_live.ex` | Rewritten: lists from Drive, PubSub, skeleton loaders, tab-focus refresh |
| `lib/phoenix_kit_document_creator/web/components/create_document_modal.ex` | Rewritten: template picker with Drive thumbnails, variable substitution |
| `mix.exs` | Removed chromic_pdf/solid deps, added req ~> 0.5 |
| `test/phoenix_kit_document_creator_test.exs` | Updated for new tab structure, version 0.2.0 |

### Files Deleted (12 files, ~5000 lines removed)

| File | Reason |
|------|--------|
| `lib/phoenix_kit_document_creator/chrome_supervisor.ex` | No local Chrome needed |
| `lib/phoenix_kit_document_creator/document_format.ex` | JSON interchange format — dead code from research spike |
| `lib/phoenix_kit_document_creator/web/components/editor_hooks.js` | GrapesJS hooks — no local editor |
| `lib/phoenix_kit_document_creator/web/components/editor_panel.ex` | GrapesJS editor panel component |
| `lib/phoenix_kit_document_creator/web/components/editor_scripts.ex` | Editor JS loading component |
| `lib/phoenix_kit_document_creator/web/document_editor_live.ex` | GrapesJS editor LiveView |
| `lib/phoenix_kit_document_creator/web/editor_pdf_helpers.ex` | Local PDF generation helpers |
| `lib/phoenix_kit_document_creator/web/editor_pdfme_test_live.ex` | pdfme test page |
| `lib/phoenix_kit_document_creator/web/editor_tiptap_test_live.ex` | TipTap test page |
| `lib/phoenix_kit_document_creator/web/header_footer_editor_live.ex` | Header/footer GrapesJS editor |
| `lib/phoenix_kit_document_creator/web/header_footer_live.ex` | Header/footer listing page |
| `lib/phoenix_kit_document_creator/web/template_editor_live.ex` | Template GrapesJS editor |
| `lib/phoenix_kit_document_creator/web/testing_live.ex` | Testing playground |
| `test/editor_pdf_helpers_test.exs` | Tests for removed module |
| `test/integration/documents_test.exs` | Integration tests for old Ecto-based CRUD |

---

## Issues Found

### CRITICAL

#### C1. SQL injection in Drive API queries (`google_docs_client.ex:150-151, 247-248`)

Folder names and folder IDs are interpolated directly into Google Drive query strings:

```elixir
q = "name = '#{name}' and mimeType = 'application/vnd.google-apps.folder' ..."
q = "'#{folder_id}' in parents and mimeType = ..."
```

While `name` is currently hardcoded (`"templates"`, `"documents"`) and `folder_id` comes from Drive itself, this is a pattern that could become exploitable if the API surface grows to accept user input. A folder name containing a single quote (`'`) would break the query and could alter its semantics.

**Fix**: Escape single quotes in interpolated values, or validate inputs are alphanumeric.

#### C2. Schemas still contain dead GrapesJS/ChromicPDF fields

All three schemas (`template.ex`, `document.ex`, `header_footer.ex`) still define fields from the old architecture that are never written to or read from in the new Google Docs flow:

- **Template**: `content_html`, `content_css`, `content_native`, `variables`, `header_uuid`, `footer_uuid`, `config`, `data`, `thumbnail`, `slug`, `status`, `description`, `created_by_uuid`
- **Document**: `content_html`, `content_css`, `content_native`, `variable_values`, `header_html`, `header_css`, `header_height`, `footer_html`, `footer_css`, `footer_height`, `config`, `data`, `thumbnail`, `template_uuid`, `created_by_uuid`
- **HeaderFooter**: `html`, `css`, `native`, `height`, `data`, `created_by_uuid` — the entire schema is unused now

The `Documents` context module no longer uses Ecto or the repo at all — it purely wraps `GoogleDocsClient`. These schemas are completely dead code.

**Fix**: Either remove the schemas entirely (if no migration concerns) or add a `@moduledoc` deprecation notice and a cleanup task to track removal. The `HeaderFooter` schema should definitely be removed since headers/footers are now handled by Google Docs natively.

#### C3. Template moduledoc still references GrapesJS (`template.ex:3-5`)

```elixir
@moduledoc """
Templates contain GrapesJS-designed content with `{{ variable }}` placeholders.
"""
```

This is misleading — GrapesJS is fully removed. The moduledoc for `Document` schema also references the old architecture ("header/footer content is baked directly").

**Fix**: Update moduledocs to reflect the Google Docs architecture.

### HIGH

#### H1. Thumbnails fetched sequentially and synchronously block the LiveView process (`documents.ex:124-134`)

```elixir
def fetch_thumbnails(files) when is_list(files) do
  files
  |> Enum.reduce(%{}, fn file, acc ->
    case GoogleDocsClient.fetch_thumbnail(file_id) do
      {:ok, data_uri} -> Map.put(acc, file_id, data_uri)
      _ -> acc
    end
  end)
end
```

Each thumbnail requires two HTTP requests (get thumbnail link, then fetch image). For 20 files, this is 40 sequential HTTP calls. While `send(self(), :load_thumbnails)` defers the work past mount, the LiveView process is blocked for the entire duration — no events are handled until all thumbnails are fetched.

**Fix**: Use `Task.Supervisor` + `Task.async_stream` for parallel fetching, or spawn a Task per thumbnail that sends results back individually:

```elixir
def fetch_thumbnails_async(files, pid) do
  Task.Supervisor.async_stream_nolink(
    MyApp.TaskSupervisor,
    files,
    fn file ->
      {file["id"], GoogleDocsClient.fetch_thumbnail(file["id"])}
    end,
    max_concurrency: 5, timeout: 15_000
  )
  |> Enum.each(fn
    {:ok, {id, {:ok, uri}}} -> send(pid, {:thumbnail, id, uri})
    _ -> :ok
  end)
end
```

#### H2. `do_load_files/2` makes two sequential Drive API calls synchronously (`documents_live.ex:88-107`)

```elixir
templates = Documents.list_templates()
documents = Documents.list_documents()
```

Each call does: `get_folder_ids()` (potentially hitting Settings + Drive API) then `list_folder_files()`. Both block the LiveView process. If Drive is slow (500ms each), that's 1+ second of unresponsive UI.

**Fix**: Use `Task.async` to fetch both lists in parallel, or at minimum cache folder IDs so they aren't re-discovered on every call.

#### H3. PubSub broadcast triggers infinite reload loop (`documents_live.ex:92-98`)

When files change, `do_load_files` broadcasts `:files_changed` to the PubSub topic. But every subscriber (including the broadcaster) handles `:files_changed` by calling `do_load_files_silent`, which calls `do_load_files` again. If the fingerprint stabilizes, it stops — but if there's clock skew on `modifiedTime` or any transient difference, multiple instances can ping-pong.

The `old_fingerprint != nil` guard prevents broadcast on first load, but doesn't prevent the self-echo loop.

**Fix**: Exclude self from PubSub broadcast, or use `Phoenix.PubSub.broadcast_from/4` which excludes the caller's PID.

#### H4. PDF download sends entire binary as base64 via WebSocket (`documents_live.ex:235-245`)

```elixir
base64 = Base.encode64(pdf_binary)
{:noreply, push_event(socket, "download-pdf", %{base64: base64, filename: filename})}
```

A 5MB PDF becomes ~6.7MB of base64 pushed through the LiveView WebSocket. This can cause:
- WebSocket frame size limits (default 10MB in Cowboy, but still risky for large docs)
- Memory pressure on the BEAM process
- Slow/janky UI during transfer

**Fix**: Write the PDF to a temp file and serve it via a Plug endpoint with a signed download URL, or use `send_download/3` if navigating away is acceptable.

#### H5. No rate limiting on Google API calls

Every `refresh`, `silent_refresh`, tab focus, and PubSub event triggers Drive API calls. A user rapidly clicking refresh or switching tabs can burn through Google API quota quickly. The 2-minute polling timer also adds up across multiple connected users.

**Fix**: Add a debounce mechanism (e.g., a minimum interval between API calls per user session). Track `last_loaded_at` in assigns and skip refresh if within cooldown.

### MEDIUM

#### M1. `@settings_key` duplicated across modules

`"document_creator_google_oauth"` is defined as a module attribute in both `GoogleDocsClient` and `GoogleOAuthSettingsLive`. If the key changes, both must be updated.

**Fix**: Define once in `GoogleDocsClient` and reference it from `GoogleOAuthSettingsLive`, or extract to a shared constant module.

#### M2. OAuth `redirect_uri` mismatch risk (`google_oauth_settings_live.ex:27, 39-40`)

The redirect URI is computed from `Routes.url()` in mount, then overridden from the browser URI in `handle_params`. If the browser sends a different origin (e.g., `http` vs `https` behind a proxy), the initial mount value and the `handle_params` value could diverge. The comment on line 42-44 acknowledges this issue but the code still sets an initial value in mount that could be stale.

**Fix**: Only set `redirect_uri` in `handle_params` (which always fires after mount). Use a placeholder in mount.

#### M3. Inline `<script>` tags in LiveView render (`documents_live.ex:417-445`)

The `open-url`, `download-pdf`, and `visibilitychange` scripts are defined inline in the render function. These re-execute on every re-render (LiveView patches). The `visibilitychange` listener accumulates duplicate handlers on re-renders.

**Fix**: Move to a Phoenix Hook (JS interop) attached to a stable DOM element, or at minimum wrap in an idempotent check.

#### M4. `create_folder/1` returns wrong status check (`google_docs_client.ex:178-179`)

```elixir
case authenticated_request(:post, "#{@drive_base}/files", json: body) do
  {:ok, %{status: 200, body: %{"id" => id}}} -> {:ok, id}
```

The Google Drive Files.create endpoint returns `200` on success, but the convention for resource creation is typically `200` for Drive (not `201`). This works, but the same pattern is used everywhere without handling other success codes (e.g., some Google APIs return `201` for create). Not a bug today, but fragile.

**Fix**: Consider matching on `status` in the `200..299` range for creation endpoints.

#### M5. `files_fingerprint/2` returns `nil` for empty lists (`documents_live.ex:583-589`)

```elixir
defp files_fingerprint([], []), do: nil
```

This means on first load with no files, `old_fingerprint` is `nil` and `new_fingerprint` is `nil`, so `changed` is `false` and thumbnails are never loaded. If a user creates their first file and the polling picks it up, `old_fingerprint` is `nil` but `new_fingerprint` is a hash — so `changed` is `true` but the guard `old_fingerprint != nil` prevents the broadcast. The logic works correctly by accident, but the `nil` sentinel is confusing.

**Fix**: Use an explicit sentinel like `:empty` or always return a hash (empty list hashes to a fixed value).

#### M6. Variable detection calls `extract_from_html` on plain text (`documents.ex:102`)

```elixir
vars = PhoenixKitDocumentCreator.Variable.extract_from_html(text)
```

The text comes from `get_document_text/1` which extracts plain text from a Google Doc — not HTML. The function name `extract_from_html` is misleading. The regex (`\{\{\s*(\w+)\s*\}\}`) works on plain text too, so it's not a bug, just a naming issue.

**Fix**: Rename to `extract_variables/1` or `extract_from_text/1` to match actual usage.

#### M7. No pagination for Drive file listing (`google_docs_client.ex:254`)

```elixir
pageSize: 100
```

If a folder has more than 100 files, the rest are silently dropped. Google Drive returns a `nextPageToken` for pagination.

**Fix**: Either implement pagination or document the 100-file limit clearly. For MVP this is acceptable but should be tracked.

### LOW

#### L1. `do_request/2` only handles `:get` and `:post` (`google_docs_client.ex:458-459`)

No `:delete` or `:patch` — if file deletion or metadata updates are needed later, this will need extending.

#### L2. Thumbnail fetch doesn't use authenticated request (`google_docs_client.ex:400-401`)

`fetch_thumbnail_image/1` uses a bare `Req.get(url)` for the thumbnail URL. Google Drive thumbnail URLs include an auth token in the URL itself, so this works. But if Google changes this behavior, thumbnails will silently fail.

#### L3. `content-type` header extraction is fragile (`google_docs_client.ex:404`)

```elixir
Enum.find_value(headers, "image/png", fn
  {"content-type", v} -> v
  _ -> nil
end)
```

Req normalizes headers, but the content-type value may include charset (e.g., `image/png; charset=utf-8`). This gets passed through to the data URI as-is, which browsers handle, but it's not clean.

#### L4. Solid dependency still in `mix.lock` but removed from `mix.exs`

The `mix.lock` was updated but Solid is listed as a transitive dependency. Should be cleaned up with `mix deps.clean --unused`.

#### L5. `Variable` moduledoc still references "Liquid/Solid syntax" (`variable.ex:5`)

Solid (Liquid) was the old template engine. The `{{ }}` syntax is now just Google Docs placeholder convention, not Liquid.

---

## Architecture Assessment

### What Went Well

1. **Massive simplification**: Removing 12 files and ~5000 lines of editor/PDF code in favor of API calls is a huge win for maintainability. No more vendored JS, no headless Chrome, no complex build pipeline.

2. **Clean API client design**: `GoogleDocsClient` is well-structured with clear sections (credentials, folders, docs, drive, internals). The `authenticated_request` + auto-refresh pattern is solid.

3. **Good UX touches**: Skeleton loaders, tab-focus refresh, PubSub cross-user updates, "open in new tab" for Google Docs — thoughtful details.

4. **OAuth settings page**: The step-by-step setup instructions are excellent for admin onboarding. The redirect URI display is a nice touch.

5. **Smart dead render handling**: Only processing OAuth callback during live WebSocket connection (not dead render) avoids the proxy redirect_uri mismatch bug.

### Concerns

1. **Synchronous HTTP in LiveView processes**: The biggest architectural concern. Every Drive API call blocks the LiveView process. With multiple users and polling, this could lead to mailbox buildup and degraded responsiveness. This should be the #1 priority fix.

2. **No error recovery**: If Google's API is down or rate-limited, the UI shows a generic error but doesn't retry or degrade gracefully. The polling timer continues firing, burning through error responses.

3. **Schemas are dead weight**: Three full Ecto schemas with changesets, validations, and associations that are never used. This will confuse future contributors.

4. **No testability for API interactions**: `GoogleDocsClient` directly calls `Req` and `Settings` — there's no behaviour/protocol for mocking in tests. The test file only tests pure functions and interface exports.

---

## Recommended Fix Priority

| Priority | Item | Effort |
|----------|------|--------|
| 1 | H1 + H2: Async thumbnail + file loading | Medium |
| 2 | C2 + C3: Clean up dead schemas and moduledocs | Low |
| 3 | H3: Fix PubSub self-echo with `broadcast_from` | Low |
| 4 | M3: Move inline scripts to Phoenix Hook | Low |
| 5 | H4: Serve PDFs via download endpoint | Medium |
| 6 | H5: Add refresh debounce/cooldown | Low |
| 7 | M1: Deduplicate settings key | Trivial |
| 8 | C1: Escape Drive query parameters | Low |
| 9 | M6 + L5: Fix naming (extract_from_html, Liquid refs) | Trivial |
| 10 | M7: Document or implement pagination | Low |
