# PR #5 Review — Migrate OAuth credentials to centralized PhoenixKit.Integrations

**Reviewer:** Pincer 🦀
**Date:** 2026-04-06
**Verdict:** Approve

---

## Summary

Migrates the document creator's Google OAuth management to the centralized Integrations system. 6 files, ~855 lines changed (significant deletions). The module now delegates all OAuth flow (authorize, exchange, refresh, userinfo) to `PhoenixKit.Integrations` and only keeps Google Docs API-specific logic.

---

## What Works Well

1. **Major code reduction** — duplicate OAuth code removed. Authorization URL generation, code exchange, token refresh, userinfo fetch — all now handled by Integrations core.
2. **Clean separation of concerns** — `GoogleDocsClient` now focuses solely on Google Docs API calls (create, copy, replace text, PDF export). OAuth is someone else's job.
3. **`required_integrations: ["google"]`** — correctly declares dependency. Admin sees Google integration setup when this module is enabled.
4. **Tests updated** — removed auth function tests, added integration declaration test. No dead tests left behind.
5. **Settings LiveView simplified** — no more OAuth flow handling in the module's settings page.

---

## Issues and Observations

### 1. OBSERVATION: Legacy GoogleDocsClient functions removed
Functions like `authorization_url/0`, `exchange_code/2`, `refresh_access_token/0`, `save_email/1` are gone. Any external code calling these directly will break. Acceptable since this is a new module with limited external usage.

### 2. OBSERVATION: `save_email/1` was used by legacy migration
The `save_email/1` helper was used during the legacy migration in phoenix_kit core (`do_migrate_legacy/2` writes `connected_email`). This is fine — the migration writes directly to settings, doesn't call document_creator code.

---

## Post-Review Status

No blockers. Clean migration. Ready for release.
