# AGENTS.md — PhoenixKit Document Creator

## Project Overview

Elixir library (Hex package) that adds document template management and PDF generation to PhoenixKit apps via Google Docs API. Templates and documents live in Google Drive. Variables use `{{ placeholder }}` syntax and are substituted via the Docs API. PDF export uses the Drive API export endpoint.

## Tech Stack

- **Language**: Elixir ~> 1.15
- **Framework**: Phoenix LiveView ~> 1.0
- **Database**: PostgreSQL (via Ecto through PhoenixKit's repo)
- **Document editing**: Google Docs (via Google Docs API v1)
- **File storage**: Google Drive (via Drive API v3)
- **Auth**: OAuth 2.0 via PhoenixKit.Integrations (centralized)
- **HTTP client**: Req ~> 0.5
- **Parent**: PhoenixKit (provides Module behaviour, Settings API, admin layout, Ecto repo, Integrations)


## Development Workflow

```
# 1. Make changes

# 2. Format code
mix format

# 3. Compile
mix compile

# 4. Check types
mix credo --strict
```

## Pre-commit Commands

Always run before git commit:

```
# 1.
mix precommit

# 2. Fix problems

# 3. Analyze current changes
git diff
git status

# 4. Make commit
```


## Project Structure

```
lib/
  phoenix_kit_document_creator.ex          # Main module — PhoenixKit.Module behaviour, tab registration
  phoenix_kit_document_creator/
    documents.ex                           # Context module — list/create/sync/export via Google Drive
    google_docs_client.ex                  # Google Docs + Drive API client with OAuth 2.0
    variable.ex                            # Extract {{ variables }} from text, guess types
    paths.ex                               # Centralized route path helpers
    schemas/
      template.ex                          # Template schema (name, slug, status, google_doc_id, path, folder_id)
      document.ex                          # Document schema (name, variable_values, google_doc_id, path, folder_id)
      header_footer.ex                     # HeaderFooter schema — legacy, deprecated
    web/
      documents_live.ex                    # LiveView — template/document listing with Drive thumbnails
      google_oauth_settings_live.ex        # LiveView — folder configuration and Google connection picker
      components/
        create_document_modal.ex           # Modal for creating documents (blank or from template with variables)

test/
  test_helper.exs                          # Smart DB detection — excludes integration tests when DB unavailable
  support/
    test_repo.ex                           # Ecto repo for tests
    data_case.ex                           # ExUnit case template with SQL Sandbox
  schemas/                                 # Unit tests for schema changesets (no DB needed)
  integration/                             # Integration tests — full CRUD + template→document workflow
  google_docs_client_test.exs              # Unit tests for GoogleDocsClient (pure functions + interface)
  phoenix_kit_document_creator_test.exs    # Unit tests for main module, variable extraction, admin tabs
```

## Key Architectural Decisions

- **Google Drive is source of truth for content**: All document content lives in Google Drive. The Phoenix app is a coordinator — it manages OAuth, lists files, substitutes variables, and exports PDFs via API.
- **Local DB mirrors metadata**: File metadata (name, google_doc_id, status, thumbnails, variables, path, folder_id) is mirrored to the local database for fast listing and audit tracking. Listing reads from DB; background sync keeps it current with Drive.
- **Four-status system**: Templates and documents have a `status` field:
  - `"published"` — file is in the expected Drive folder (normal state)
  - `"trashed"` — soft-deleted via app (moved to deleted folder) or found in Drive trash
  - `"lost"` — disappeared from Drive (manually deleted by someone in Google). Recovers automatically if reappearing.
  - `"unfiled"` — exists in Drive but outside the configured managed folders. The UI provides a resolution popup (move to templates/documents, or accept current location).
- **Path and folder tracking**: Each template/document record stores `path` (human-readable folder path) and `folder_id` (Drive folder ID) for its accepted location. Used during reconciliation to determine if a file is in the right place.
- **Variable tracking**: When creating a document from a template, `variable_values` (the actual substitution values) are persisted to the Document record for debugging. Variable definitions detected in templates are saved to the Template `variables` field.
- **No local editor**: Editing happens in Google Docs. No GrapesJS, TipTap, or other JS editors.
- **No local PDF generation**: PDFs are exported via the Drive API. No ChromicPDF, Gotenberg, or Chrome dependency.
- **Credentials via PhoenixKit.Integrations**: Google OAuth credentials (client_id/secret, access/refresh tokens) are managed centrally by `PhoenixKit.Integrations` under the `"google"` provider. The module declares `required_integrations: ["google"]`. Legacy `document_creator_google_oauth` settings key is auto-migrated to `integration:google:default` on first access.
- **Auto-refresh on 401**: API calls go through `PhoenixKit.Integrations.authenticated_request/4` which automatically refreshes expired access tokens.
- **Folder config stored separately**: Folder paths and cached folder IDs are stored in `"document_creator_folders"` settings key (not in the integration data).
- **Connection selection**: The module stores the selected Google connection UUID in `"document_creator_settings"` → `"google_connection"`. Multiple Google connections are supported via the integration picker component.
- **No own Ecto repo**: Uses the host app's repo via `PhoenixKit.RepoHelper.repo()`.

## Data Flow

```
Mount → DB read (instant) → render
         ↓ (background)
Google Drive API → upsert DB → reconcile status → re-read DB → update assigns
```

- **Sync**: `Documents.sync_from_drive/0` fetches files from Drive, upserts to DB with `status: "published"`, then runs `reconcile_status` which checks each tracked record against Drive and classifies as published/lost/trashed/unfiled.
- **Create**: After Google API creates/copies a file, the DB record is immediately written with path/folder_id.
- **Delete**: After moving a file to the Drive deleted folder, the DB status is set to "trashed".
- **Unfiled resolution**: Files outside managed folders can be moved to templates/documents or their current location can be accepted as correct.
- **Thumbnails**: Fetched async from Drive, persisted to DB, loaded from DB cache on page load.

## Database Tables (V86 + V94)

Migration V86 (core) creates the tables. V94 adds `google_doc_id`, `status`, `path`, and `folder_id` columns.

- `phoenix_kit_doc_templates` — name, slug, status, google_doc_id (partial unique), path, folder_id, variables (jsonb), thumbnail, config, data
- `phoenix_kit_doc_documents` — name, google_doc_id (partial unique), status, path, folder_id, template_uuid (FK), variable_values (map), thumbnail, config, data
- `phoenix_kit_doc_headers_footers` — legacy, deprecated (headers/footers handled by Google Docs natively)

**Note:** Migrations live in PhoenixKit core (`lib/phoenix_kit/migrations/postgres/`), not in this module.

## Public API Layers

The module exposes two complementary APIs:

1. **`PhoenixKitDocumentCreator.GoogleDocsClient`** — Direct Google Drive/Docs API access. No local DB operations. Use for: creating files, listing folders, moving files, exporting PDFs, reading document content, template variable substitution. Another module can use this to interact with Google Drive directly.

2. **`PhoenixKitDocumentCreator.Documents`** — Combined Drive + DB operations. Coordinates between Google Drive and the local database. Includes DB-only functions (`list_templates_from_db`, `load_cached_thumbnails`) and combined functions (`create_template`, `sync_from_drive`, `delete_document`). All public functions have `@spec` annotations. Mutating functions accept `opts` with `:actor_uuid` for activity logging.

## Critical Conventions

- **Module key**: `"document_creator"`
- **Tab IDs**: `:admin_document_creator`, `:admin_document_creator_documents`, `:admin_document_creator_templates`
- **URL paths**: Use hyphens (`document-creator`, `document-creator/templates`)
- **Settings keys**: `"document_creator_enabled"`, `"document_creator_settings"`, `"document_creator_folders"`
- **Translations**: All user-facing strings use `gettext()` via `PhoenixKitWeb.Gettext` backend
- **CSS sources**: `css_sources/0` returns `[:phoenix_kit_document_creator]` for Tailwind scanning
- **Required integrations**: `["google"]` — declares dependency on Google provider

## Running Tests

```bash
# Unit tests only (no database needed)
mix test --exclude integration

# All tests (requires PostgreSQL)
createdb phoenix_kit_document_creator_test
mix test
```

### Code Search

- Use `rg` (ripgrep) for text/regex/strings/comments
- Use `ast-grep` for structural patterns/function calls/refactoring

**Prefer `ast-grep` over text-based grep for structural code searches.**

```bash
ast-grep --lang elixir --pattern 'Documents.$FUNC($$$)' lib/
ast-grep --lang elixir --pattern 'def handle_event($$$) do $$$BODY end' lib/
```

## Common Tasks

- **Adding admin tabs**: Register in `phoenix_kit_document_creator.ex` `admin_tabs/0` callback.
- **Adding new API operations**: Add to `google_docs_client.ex` using `authenticated_request/3` for auto-refresh.
- **Adding path helpers**: Add to `paths.ex`.
- **Changing OAuth flow**: OAuth is managed centrally by `PhoenixKit.Integrations`. The `GoogleDocsClient` uses `Integrations.authenticated_request/4` for API calls with auto-refresh.
- **Handling unfiled files**: Use `Documents.move_to_templates/1`, `Documents.move_to_documents/1`, or `Documents.set_correct_location/1`.

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

- Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`
- **NEVER mention Claude or AI assistance** in commit messages

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md`.
