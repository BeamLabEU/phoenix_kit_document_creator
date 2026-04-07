# PR #6 Review — Add local DB sync, activity logging, translations, quality hardening

**Reviewer:** Pincer 🦀
**Date:** 2026-04-07
**Verdict:** Approve with Observations

---

## Summary

Major feature PR adding local document tracking, activity logging, i18n, and quality improvements. 11 files, ~1755 lines added, ~1093 removed (OAuth code cleanup).

### Key additions:
1. **Local DB sync** — Documents tracked with `google_doc_id`, `status`, `path`, `folder_id` fields
2. **Document status enum** — `draft`, `synced`, `error` with proper changeset validations
3. **Activity logging** — `log_activity/3` for tracking document operations
4. **Gettext translations** — All user-visible strings wrapped
5. **Create document modal** — New component for creating from templates
6. **Documents LiveView** — List view with status and sync indicators
7. **Google Docs client updated** — Uses Integrations for auth, adds folder support
8. **OAuth settings LiveView removed** — Now fully handled by Integrations

---

## What Works Well

1. **Clean status management** — `draft` → `synced` → `error` lifecycle with proper transitions
2. **Changeset validations** — `google_doc_id` format validation, status enum enforcement
3. **Activity logging** — Structured activity records with metadata, useful for debugging
4. **OAuth cleanup** — Finally removed the local OAuth settings LiveView entirely
5. **Folder support** — Documents can be organized in Google Drive folders
6. **Good test coverage** — Tests for schema, changeset, activity logging, status transitions

---

## Issues and Observations

### 1. DESIGN — MEDIUM: Large PR bundles multiple features
This PR does 4 things at once (DB sync, activity logging, translations, UI). Would be easier to review as separate PRs. But the code is clean.

### 2. OBSERVATION: `log_activity/3` stores activities in JSONB
Activity logs are stored as settings entries. This works but could grow large over time. No cleanup/pagination mentioned.

### 3. OBSERVATION: No sync scheduler/worker
The PR adds sync tracking but no Oban worker to periodically sync documents. This might come in a follow-up PR.

---

## Post-Review Status

No blockers. Feature-rich but well-structured PR. Ready for release.
