# Claude Review: PR #1 — Add Document Creator Module

**Review Date**: 2026-03-24
**AI Reviewer**: Claude (Opus 4.6)
**PR**: https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/1
**Status**: ✅ Merged (post-merge review)

## Summary

Strong initial implementation with solid architectural decisions (baking pattern, lazy Chrome, versioned migrations). The PR went through a clear evolution — from research spike through to production-ready module with 115 tests. Three security issues and several logic bugs should be addressed in follow-up work.

## Critical Issues

### 🔴 1. Stored XSS via Thumbnail Iframes

**Files**: `web/editor_pdf_helpers.ex`, `web/documents_live.ex`, `web/components/create_document_modal.ex`

Thumbnails are generated as `data:text/html;base64,...` URIs containing unsanitized user HTML/CSS from GrapesJS, then loaded in iframes **without a `sandbox` attribute**:

```html
<iframe src={@thumbnail} scrolling="no" style="..." />
```

Any admin who edits template content can inject JavaScript that executes in other admins' browsers when viewing the listing page. Even in an admin-only context, this enables privilege escalation if different admin roles exist.

**Fix**: Add `sandbox=""` attribute to all thumbnail iframes, or generate actual image thumbnails (e.g., via ChromicPDF screenshot).

### 🔴 2. SQL Interpolation in Migrations

**Files**: `migration.ex`, `migration/postgres/v02.ex`, `migration/postgres/v04.ex`

The prefix escaping uses `String.replace(prefix, "'", "\\'")` which is **not valid PostgreSQL escaping** — the standard escape is `''`. The escaped prefix is then interpolated directly into raw SQL:

```elixir
WHERE table_schema = '#{escaped_prefix}'
```

While the prefix defaults to `"public"` and is unlikely to come from user input, this establishes a dangerous pattern. The same direct interpolation appears in V02 and V04 `UPDATE`/`SELECT` statements.

**Fix**: Use `''` for escaping, or better yet, use parameterized queries via `Ecto.Adapters.SQL.query(repo, sql, [prefix])` with `$1` placeholders.

### 🔴 3. CSS Injection in Thumbnails

**File**: `web/editor_pdf_helpers.ex`

User-supplied CSS is injected unsanitized into `<style>` tags in thumbnail HTML:

```elixir
css_block = if is_binary(css) and css != "", do: "<style>#{css}</style>", else: ""
```

Combined with the unsandboxed iframes from issue #1, CSS `url()` or `@import` can be used for data exfiltration.

**Fix**: Resolved by sandboxing the iframes (issue #1 fix).

## High Severity Issues

### 🟠 4. Race Condition in ChromeSupervisor.ensure_started/0

**File**: `chrome_supervisor.ex`

```elixir
def ensure_started do
  if chromic_pdf_running?() do
    :ok
  else
    start_chromic_pdf()
  end
end
```

Check-then-act is not atomic. Two concurrent PDF requests can both see `chromic_pdf_running?()` as `false` and attempt to start ChromicPDF simultaneously. While `start_child` handles `{:error, {:already_started, _}}`, the intermediate `maybe_start_supervisor` has the same TOCTOU race.

**Fix**: Use a GenServer or `:global` lock to serialize startup, or handle all `{:error, {:already_started, _}}` tuples gracefully in `start_chromic_pdf/0`.

### 🟠 5. `published_templates/0` Returns Drafts

**File**: `documents.ex`

```elixir
def published_templates do
  list_templates()
end
```

`list_templates/0` returns all non-trashed templates (including drafts), so the "create document from template" modal shows draft templates to users.

**Fix**: Filter by `status == "published"` in the query.

### 🟠 6. Stale Struct After Thumbnail Save

**Files**: `web/document_editor_live.ex`, `web/template_editor_live.ex`

```elixir
case Documents.update_document(socket.assigns.document, attrs) do
  {:ok, document} ->
    case EditorPdfHelpers.generate_thumbnail_html(html, css: css) do
      {:ok, thumb_html} -> Documents.update_document(document, %{thumbnail: thumb_html})
      _ -> :ok
    end
    {:noreply, assign(socket, document: document, ...)}
```

The socket is assigned the document from the first update, but the second `update_document` (for thumbnail) returns a different struct. The socket keeps the stale version without the updated thumbnail.

**Fix**: Use the result of the second update: `{:ok, doc_with_thumb} = Documents.update_document(...)` and assign that.

### 🟠 7. Regex Backreference Bug in Variable Rendering

**File**: `documents.ex`

```elixir
String.replace(acc, ~r/\{\{\s*#{Regex.escape(key)}\s*\}\}/, to_string(value))
```

If a variable's value contains `\\1` or other regex replacement patterns, `String.replace/3` treats them as backreferences.

**Fix**: Use function replacement: `String.replace(acc, regex, fn _ -> to_string(value) end)`.

## Medium Severity Issues

### 🟡 8. No UUID Validation on URL Parameters

**Files**: `web/document_editor_live.ex`, `web/template_editor_live.ex`, `web/header_footer_editor_live.ex`

`handle_params(%{"uuid" => uuid}, ...)` passes user-supplied `uuid` directly to `Repo.get()`. Invalid UUIDs raise `Ecto.Query.CastError` instead of returning a 404.

**Fix**: Validate UUID format before querying, or rescue `CastError` and redirect.

### 🟡 9. No Size Limit on Thumbnail Column

**Files**: `schemas/document.ex`, `schemas/template.ex`

The `thumbnail` field stores base64-encoded HTML with no length validation. These are loaded for all records on listing pages — can grow expensive.

**Fix**: Add `validate_length(changeset, :thumbnail, max: 100_000)` or generate compressed image thumbnails instead.

### 🟡 10. Missing Height Format Validation

**File**: `schemas/header_footer.ex`

Height is validated for max 20 characters but not for valid CSS length format (e.g., `"25mm"`, `"1in"`). Any string passes.

**Fix**: Add a regex validation: `validate_format(changeset, :height, ~r/^\d+(\.\d+)?(mm|cm|in|px|pt)$/)`.

### 🟡 11. `String.to_existing_atom/1` Crash Risk

**Files**: `web/document_editor_live.ex`, `web/template_editor_live.ex`

In `format_changeset_errors`, the key from Ecto interpolation is passed to `String.to_existing_atom/1`. Custom validators could introduce keys that haven't been atomized, causing `ArgumentError`.

**Fix**: Use `String.to_atom/1` (safe here since keys come from internal Ecto validation, not user input) or wrap in a `try/rescue`.

### 🟡 12. Template Slug Collision

**File**: `schemas/template.ex`

`maybe_generate_slug/1` generates a slug from the name. Two templates named "Service Agreement" both get `"service-agreement"` — the second insert fails with a bare constraint error.

**Fix**: Auto-append a counter or short UUID suffix on collision.

## Low Severity / Code Quality

### 🔵 13. `phoenix_kit` Dependency Uses Local Path

**File**: `mix.exs`

```elixir
{:phoenix_kit, path: "../phoenix_kit"},
```

Should be a hex.pm dependency for release. The README correctly shows `{:phoenix_kit_document_creator, "~> 0.2"}` but the dep itself is local.

### 🔵 14. `DocumentFormat` Module Is Mostly Dead Code

**File**: `document_format.ex`

The `to_json/1`, `from_json/1`, `to_json_string/1`, and `new/2` functions are unused. Templates and documents store HTML/CSS as separate columns, not as a single JSON blob. Only `extract_variables/1` and `sample_html/0` are referenced.

### 🔵 15. Duplicated Logic

- `humanize/1` is implemented identically in `variable.ex`, `template_editor_live.ex`, and `create_document_modal.ex`
- `extract_variables` logic exists in both `DocumentFormat` and `Variable`

Should be extracted to a shared utility.

### 🔵 16. Blanket Rescue in `enabled?/0`

**File**: `phoenix_kit_document_creator.ex`

```elixir
def enabled? do
  Settings.get_boolean_setting("document_creator_enabled", false)
rescue
  _ -> false
end
```

Swallows all errors including configuration bugs and DB connection failures. Should rescue specific expected exceptions.

### 🔵 17. Listing Page Performance

**File**: `web/documents_live.ex`

Each template/document card renders a full HTML document in an iframe. On pages with 20+ items, this creates N separate browsing contexts with their own DOMs, causing memory and rendering overhead.

## Positive Findings

### ✅ Baking Pattern (V04)

The decision to copy header/footer content into documents at creation time is excellent. It eliminates FK coupling, makes documents self-contained, and prevents data integrity issues when headers/footers are deleted. The migration correctly copies data before dropping FKs.

### ✅ Test Infrastructure

115 tests with smart DB detection — integration tests are automatically excluded when PostgreSQL is unavailable. The `DataCase` with SQL Sandbox follows PhoenixKit's established pattern.

### ✅ Versioned Migration System

V01–V04 with auto-discovery via `mix phoenix_kit.update` is clean and follows PhoenixKit conventions.

### ✅ Centralized Paths Module

Replacing fragile relative paths and string concatenation with `Paths` helpers eliminates a common source of routing bugs.

### ✅ Lazy Chrome Startup

Starting ChromicPDF only on first PDF export is a smart design — keeps the module lightweight when enabled but not actively generating PDFs.

### ✅ Commit History

20 well-structured commits tell a clear story from research spike → editor fixes → feature buildout → baking pattern → tests. Each commit has detailed body text explaining what and why.

## Recommended Follow-up Priority

1. **Sandbox thumbnail iframes** (Critical — XSS)
2. **Fix SQL prefix escaping** (Critical — establishes bad pattern)
3. **Fix stale struct after thumbnail save** (High — data inconsistency)
4. **Fix regex backreference in variable rendering** (High — silent data corruption)
5. **Add UUID validation on URL params** (Medium — unhandled crashes)
6. **Filter published_templates properly** (High — shows drafts)
7. **Clean up dead code in DocumentFormat** (Low — maintenance burden)
8. **Extract duplicated humanize/extract_variables** (Low — DRY)
