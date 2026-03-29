# AGENTS.md — PhoenixKit Document Creator

## Project Overview

Elixir library (Hex package) that adds document template management and PDF generation to PhoenixKit apps via Google Docs API. Templates and documents live in Google Drive. Variables use `{{ placeholder }}` syntax and are substituted via the Docs API. PDF export uses the Drive API export endpoint.

## Tech Stack

- **Language**: Elixir ~> 1.15
- **Framework**: Phoenix LiveView ~> 1.0
- **Database**: PostgreSQL (via Ecto through PhoenixKit's repo)
- **Document editing**: Google Docs (via Google Docs API v1)
- **File storage**: Google Drive (via Drive API v3)
- **Auth**: OAuth 2.0 (Google)
- **HTTP client**: Req ~> 0.5
- **Parent**: PhoenixKit (provides Module behaviour, Settings API, admin layout, Ecto repo)

## Project Structure

```
lib/
  phoenix_kit_document_creator.ex          # Main module — PhoenixKit.Module behaviour, tab registration
  phoenix_kit_document_creator/
    documents.ex                           # Context module — list/create/export via Google Drive
    google_docs_client.ex                  # Google Docs + Drive API client with OAuth 2.0
    variable.ex                            # Extract {{ variables }} from text, guess types
    paths.ex                               # Centralized route path helpers
    schemas/
      template.ex                          # Template schema (name, slug, status, google_doc_id)
      document.ex                          # Document schema (name, variable_values, google_doc_id)
      header_footer.ex                     # HeaderFooter schema (type discriminator: "header" | "footer")
    web/
      documents_live.ex                    # LiveView — template/document listing with Drive thumbnails
      google_oauth_settings_live.ex        # LiveView — Google OAuth settings (connect/disconnect)
      components/
        create_document_modal.ex           # Modal for creating documents (blank or from template with variables)

test/
  test_helper.exs                          # Smart DB detection — excludes integration tests when DB unavailable
  support/
    test_repo.ex                           # Ecto repo for tests
    data_case.ex                           # ExUnit case template with SQL Sandbox
  schemas/                                 # Unit tests for schema changesets (no DB needed)
  integration/documents_test.exs           # Integration tests — full CRUD + template→document workflow
  google_docs_client_test.exs              # Unit tests for GoogleDocsClient (pure functions + interface)
  phoenix_kit_document_creator_test.exs    # Unit tests for main module, variable extraction, admin tabs
```

## Key Architectural Decisions

- **Google Drive is source of truth**: All document content lives in Google Drive. The Phoenix app is a coordinator — it manages OAuth, lists files, substitutes variables, and exports PDFs via API.
- **No local editor**: Editing happens in Google Docs. No GrapesJS, TipTap, or other JS editors.
- **No local PDF generation**: PDFs are exported via the Drive API. No ChromicPDF, Gotenberg, or Chrome dependency.
- **OAuth credentials in Settings**: Stored as a JSON blob via `PhoenixKit.Settings` under key `"document_creator_google_oauth"`.
- **Auto-refresh on 401**: The `GoogleDocsClient` automatically refreshes expired access tokens when a request returns 401.
- **Folder convention**: Templates go in a `/templates` folder, documents in `/documents` — both in the Drive root. Folder IDs are cached in Settings.
- **No own Ecto repo**: Uses the host app's repo via `PhoenixKit.repo()`.

## Running Tests

```bash
# Unit tests only (no database needed)
mix test --exclude integration

# All tests (requires PostgreSQL)
createdb phoenix_kit_document_creator_test
mix test
```

## Common Tasks

- **Adding admin tabs**: Register in `phoenix_kit_document_creator.ex` `admin_tabs/0` callback.
- **Adding new API operations**: Add to `google_docs_client.ex` using `authenticated_request/3` for auto-refresh.
- **Adding path helpers**: Add to `paths.ex`.
- **Changing OAuth flow**: `google_docs_client.ex` handles credential storage, token exchange, and refresh.

## Versioning & Releases

Version is tracked in three places — all must match:
1. `mix.exs` — `@version`
2. `lib/phoenix_kit_document_creator.ex` — `def version, do: "x.y.z"`
3. `test/phoenix_kit_document_creator_test.exs` — version compliance test

### Tagging convention

Use **bare version numbers** (no `v` prefix): `0.2.0`, not `v0.2.0`.

### Release checklist

1. Update version in all three locations above
2. Add entry to `CHANGELOG.md`
3. Commit: `Bump version to x.y.z`
4. Push to main
5. Tag: `git tag x.y.z && git push origin x.y.z`
6. GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "See CHANGELOG.md"`

## Pull Requests

- Start commit messages with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`
- **NEVER mention Claude or AI assistance** in commit messages
- Document significant PRs in `dev_docs/pull_requests/` — see `TEMPLATE.md` there
