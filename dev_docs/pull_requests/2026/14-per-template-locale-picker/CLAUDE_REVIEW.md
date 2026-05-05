# PR #14 Review — Per-template locale picker (issue #13) + close PR #11/#12 parking-lot items

**Author:** Max Don (`mdon`)
**Reviewer:** Dmitri + Claude (Opus 4.7)
**Merged:** 2026-05-05 (`edb387b`)
**Range:** `16aa2e0..edb387b` — 4 commits, +1152/-183 across 17 files
**Depends on:** `BeamLabEU/phoenix_kit#515` (V110 + `PhoenixKit.Migration.ensure_current/2`)

## TL;DR

Solid, well-scoped work. The per-template `:language` field is the right
shape (single-language templates owned by the parent app, locale stored
as a full BCP-47 code, documents inherit), the M1 mount→handle_info
cutover finally kills the duplicate-mount-read burst on both LiveViews,
and the §1.2 boot-vs-lazy symmetry fix from the PR #12 follow-up list
is the right call — surfacing "no exact match" cleanly beats silently
picking an arbitrary connection. **No blocking findings.** Two real
concerns worth a follow-up:

1. **[MEDIUM] Browser compat for the popover picker.** CSS Anchor
   Positioning (`anchor-name` / `position-anchor` / `position-area`)
   isn't in Firefox yet — admins on Firefox will see the popover open
   *unanchored* (default top-of-viewport, not under the badge).
2. **[LOW] `apply_template_language/2` bypasses the changeset.** The
   create-time language stamp uses `update_all` so the V110 column-
   length validation never runs; a future stray long code from
   `Languages.get_default_language/0` would surface as a Postgrex
   exception instead of a clean changeset error.

Plus a handful of NITs. Tests are thorough (six schema tests, nine
integration tests, three LV tests for the new path), `mix precommit`
clean, integration suite green when DB is reachable.

---

## 1. Findings

### 1.1 [MEDIUM] Firefox: popover renders unanchored

**Where:** `lib/phoenix_kit_document_creator/web/documents_live.ex:1252-1312`
(`render_language_picker/1`)

The picker uses three CSS features in concert:

```elixir
style={"anchor-name: --lang-trigger-#{@file["id"]}"}
...
style={
  "position-anchor: --lang-trigger-#{@file["id"]}; " <>
  "position-area: bottom span-right; " <>
  "margin: 4px 0 0 0; inset: auto;"
}
```

Browser support for these properties as of this writing:

| Feature              | Chrome/Edge | Safari | Firefox |
|----------------------|-------------|--------|---------|
| `popover` attr       | 114+        | 17+    | 125+    |
| `anchor-name`        | 125+        | 26+    | **no**  |
| `position-anchor`    | 125+        | 26+    | **no**  |
| `position-area`      | 125+        | 26+    | **no**  |

In Firefox the `popover` itself opens (the native API works), but
without anchor positioning the `position-area: bottom span-right`
declaration is dropped on the floor and the popover renders at the
spec-default position — generally pinned to the top-left of the
viewport, ignoring the trigger badge. `[&:not(:popover-open)]:hidden`
still gates visibility, so it's not a click-eats-the-page bug, but
the picker is unusable on Firefox until they ship anchor positioning
(currently behind `layout.css.anchor-positioning.enabled` in
nightly).

**Why the smoke check missed it:** PR description says browser smoke
on `phoenix_kit_parent` showed "0 console errors" — true, since
unsupported CSS just gets dropped silently. The popover *opened*; it
just opened in the wrong place.

**Suggested fix (any of these would close it):**
- Add a JS fallback that runs `getBoundingClientRect()` on the trigger
  and absolute-positions the popover when `CSS.supports("anchor-name:
  --x")` is false. Native API doesn't expose the trigger to the
  popover, but `popovertarget` is on the trigger so you can
  `addEventListener("toggle", ...)` and use `event.target.previousElementSibling`-ish DOM walking. ~15 lines of vanilla JS.
- Use a JS-positioned dropdown library (Floating UI is the standard).
  Heavier dependency but works everywhere.
- Document Firefox as unsupported and gate the picker with a
  user-agent check + fallback to a `<select>`.

I lean toward the JS fallback — a `<select>` works but loses the
multi-line "code + name" affordance the popover gives. Whichever, the
status quo is a regression for Firefox-using admins.

---

### 1.2 [LOW] `apply_template_language/2` bypasses changeset validation

**Where:** `lib/phoenix_kit_document_creator/documents.ex:559-582`

```elixir
defp apply_template_language(doc_id, language) when is_binary(language) do
  {count, _} =
    Template
    |> where([t], t.google_doc_id == ^doc_id)
    |> repo().update_all(set: [language: language])
  ...
end
```

Used by `create_template/2` to stamp the freshly-created Drive doc
with the project's primary language. `update_all` skips the
`Template.changeset/2` validations — including
`validate_length(:language, max: 10)` that the rest of the language
write path (`update_template_language/3`) honors.

In practice the input is `Languages.get_default_language().code` and
the V110 column is `varchar(10)`, so a misconfigured Languages row
returning `"some-very-long-code"` would fail at the Postgrex layer
with a `value too long for type character varying(10)` exception —
not a clean `{:error, %Ecto.Changeset{}}`. The exception path is
caught by `:rescue` clauses elsewhere in the create flow but bubbles
through `apply_template_language` unhandled (the `update_all` line
isn't wrapped). The Drive doc would already exist; the language
stamp would crash the LV's `handle_event("new_template", ...)`
caller and leave the template with `language: nil`.

**Suggested fix:** route through the same code path as
`update_template_language/3`:

```elixir
defp apply_template_language(doc_id, language) when is_binary(language) do
  case repo().get_by(Template, google_doc_id: doc_id) do
    nil ->
      Logger.warning("[DocumentCreator] apply_template_language no-op | ...")
      :ok

    template ->
      template
      |> Template.changeset(%{language: language})
      |> repo().update()
      |> case do
        {:ok, _} -> :ok
        {:error, cs} ->
          Logger.warning("[DocumentCreator] apply_template_language invalid | errors=#{inspect(cs.errors)}")
          :ok
      end
  end
end
```

Two more queries on the create path (a `get_by` and an `update`) but
brings the create-time and post-create write paths to the same
validation surface.

---

### 1.3 [LOW] `set_template_language` event re-reads the entire templates list

**Where:** `lib/phoenix_kit_document_creator/web/documents_live.ex:296-300`

```elixir
case Documents.update_template_language(file_id, language, actor_opts(socket)) do
  {:ok, _template} ->
    templates = Documents.list_templates_from_db()
    {:noreply, assign(socket, templates: templates)}
```

`update_template_language/3` already returns the updated template
struct AND broadcasts `:files_changed`. The LV then re-reads
`list_templates_from_db/0` (one DB round-trip, all templates) just to
update one row's `"language"` value in the `:templates` assign.

The broadcast self-echo is correctly filtered by
`from_pid != self()` in `handle_info({:files_changed, ...}, ...)`,
so we don't sync twice — but the per-event re-read still happens.

**Suggested fix:** mutate the assign directly:

```elixir
{:ok, updated} ->
  templates =
    Enum.map(socket.assigns.templates, fn t ->
      if t["id"] == file_id, do: Map.put(t, "language", updated.language), else: t
    end)
  {:noreply, assign(socket, templates: templates)}
```

Saves the round-trip and keeps the optimistic-update story consistent
with `apply_optimistic_move/3` for delete/restore. Low-priority.

---

### 1.4 [NIT] `default_language_code/0` falls through `nil` implicitly

**Where:** `lib/phoenix_kit_document_creator/documents.ex:543-557`

```elixir
defp default_language_code do
  if Code.ensure_loaded?(Languages) do
    try do
      ...
    rescue ...
    catch ...
    end
  end   # <-- no else; returns nil when Languages module isn't loaded
end
```

Correct, but the `nil` fallthrough relies on Elixir's `if`-without-`else`
returning `nil` — easy to misread on first scan. The sibling
`list_enabled_languages/0` ten lines up has an explicit `else: []`
branch for the same condition. Adding `else: nil` to
`default_language_code/0` would make the intent explicit and match
the local style.

---

### 1.5 [NIT] `update_template_language/3` revalidates every optional field

**Where:** `lib/phoenix_kit_document_creator/documents.ex:861-864`

```elixir
%Template{language: previous} = template ->
  template
  |> Template.changeset(%{language: normalized})
  |> repo().update()
```

`Template.changeset/2` casts `@required_fields ++ @optional_fields` —
20-ish fields including `:slug`, `:status`, `:variables`, `:config`,
`:data`, `:thumbnail`, etc. With `attrs = %{language: "et-EE"}` only
`:language` is in changes, but the changeset still runs
`validate_length(:name, ...)`, `validate_inclusion(:status, ...)`,
`maybe_generate_slug/1`, and `unique_constraint(:slug)` against the
loaded record. Since the loaded record is valid by construction this
is fine, but the Ecto idiom for this kind of single-field write is a
purpose-built changeset:

```elixir
def language_changeset(template, attrs) do
  template
  |> cast(attrs, [:language])
  |> validate_length(:language, max: 10)
end
```

Same shape as `sync_changeset/2`. Closes the cross-context invariant
that "different operations get different changesets" (per
`ecto-thinking`'s "multiple changesets per schema" rule).

Worth doing at the same time as §1.2 — both writes route through one
focused changeset, removing the create-vs-update validation gap.

---

### 1.6 [NIT] `enabled_languages` is read once at mount, never refreshed

**Where:** `lib/phoenix_kit_document_creator/web/documents_live.ex:128`

```elixir
enabled_languages: Documents.list_enabled_languages(),
```

Loaded in `:load_initial`, never re-read for the lifetime of the LV
session. If an admin enables/disables a language in
`PhoenixKit.Modules.Languages` settings while another admin tab has
the templates page open, the picker won't reflect the change until
that tab reloads.

This is probably fine — language config changes are rare, the
picker's failure mode is "doesn't show a newly-enabled language
until refresh." Worth a one-line note in `:files_changed` (or a
parallel `:languages_changed` topic) if Languages settings start
broadcasting their own pubsub event. **Not actionable today.**

---

### 1.7 [NIT] Dead `_ = changeset` in `update_template_language/3`

**Where:** `lib/phoenix_kit_document_creator/documents.ex:884-891`

```elixir
{:error, changeset} = err ->
  log_failed_mutation("template.language_updated", "template", opts, %{
    "google_doc_id" => google_doc_id,
    "language_to" => normalized
  })

  _ = changeset
  err
```

The `_ = changeset` is a no-op — it doesn't suppress the unused-binding
warning because the binding is *used* in the pattern match (it would be
a warning if `changeset` were truly unused, but it's destructured). Looks
like a leftover from an iteration where the changeset was logged. Drop
the line.

---

## 2. Things done well

- **Mount→handle_info cutover (M1) is the right shape on both LVs.**
  `mount/3` returns an empty shell with `loaded: false`, `connected?`
  gates the work, `send(self(), :load_*)` does the actual reads in
  the connected lifecycle. Subscribe-before-read on the documents LV
  (`PhoenixKit.PubSubHelper.subscribe(@pubsub_topic)` then
  `send(self(), :load_initial)`) closes the read-then-subscribe race
  cleanly. The comment block at `documents_live.ex:25-32` documenting
  the rationale is exactly what future readers need.
- **`Task.Supervisor.async_stream_nolink` for `discover_folders/0`
  (S2)** is the textbook fix for the "Task.async leaks the link" pattern
  flagged in the OTP skill. The new pattern-match shape on
  `{:ok, {:ok, _}}` / `{:ok, {:error, _}}` / `{:exit, _}` makes the
  three failure modes explicit; the explicit `catch :exit, _` block is
  gone and the comment at `google_docs_client.ex:417-435` explaining
  the swap is excellent.
- **Symmetric §1.2 fix between boot and lazy migration paths** is the
  correct resolution — the previous "lazy path silently picks the first
  connection" fallback was a real foot-gun for multi-account installs.
  The PR-#12 follow-up review explicitly called for "either symmetry
  or strictness;" picking strictness is the right call. Both paths now
  log a warning + activity row on failure, which gives ops the audit
  trail that was missing from the lazy path.
- **`Test.StubIntegrations.claim!/0`** with the `:owner_pid` ETS key
  and the `Process.alive?(other)` reclaim path is a clean solution to
  the §1.9 cross-process boundary problem. The raise message is loud
  and specific (`pid=#{inspect(other)}` ... `pid=#{inspect(me)}` ...
  `must declare async: false`), which makes the violation impossible
  to miss.
- **`Documents.update_template_language/3`'s activity-log shape** —
  both happy and failure paths emit a `template.language_updated`
  row, with `language_from`/`language_to` metadata on success and
  `db_pending: true` on the failure side. Matches the pattern from
  the §1.1 audit trail work. The integration test pinning both rows
  (`test/integration/documents_test.exs:747-785`) is exactly the
  right level of detail.
- **`sync_changeset/2` deliberately omits `:language` from its cast
  allowlist.** The regression test
  (`test/schemas/template_test.exs:191-205`) pinning that admin-set
  values survive Drive sync is precisely the right invariant to lock
  in — if a future refactor drops `:language` from `@optional_fields`
  back into the sync allowlist, that test fails before the bug ships.
- **`already_migrated?/0` swap with `function_exported?/3` + `apply/3`
  + `credo:disable-for-next-line`** is the correct way to soft-depend
  on a not-yet-published core helper. The fallback to legacy
  `get_integration("provider:name")` lookup keeps the boot path
  working against the current Hex floor. The disable directive is
  scoped to the single line.
- **Feature flag for `enabled_languages` is implicit and correct** —
  `Documents.list_enabled_languages/0` returns `[]` when the
  Languages module isn't loaded; the picker's `:if={@is_template and
  @status_mode != "trashed" and @enabled_languages != []}` guard
  hides the badge entirely on installs that don't have the module
  enabled. No "language? what language?" stub badge to confuse
  admins.
- **`Web.Helpers` extraction (S5)** is small and the right scope —
  two functions, both with `@spec`, both used by both LVs. Drops a
  6-line duplicated `actor_uuid/1` from
  `google_oauth_settings_live.ex` and unifies the contract for
  future cross-cutting helpers. The thin `defp actor_uuid(socket),
  do: Helpers.actor_uuid(socket)` shim in the settings LV preserves
  the call-site name, which keeps the diff small.
- **`apply_template_language/2`'s `count == 0` warning log** — even
  though the path is theoretically unreachable from the admin UI
  (the row was just upserted three lines up), the `Logger.warning`
  on no-op preserves visibility for the future-OTP-message path the
  comment calls out. Don't normally praise dead-code logging, but
  here the comment explains *why* this is defensive on purpose, and
  that's the rare case where it's worth keeping.

---

## 3. What I'd like to fix in this branch

If you're OK with it, I'd push two follow-up commits:

1. **§1.2 — route `apply_template_language/2` through a focused
   `Template.language_changeset/2`** (also fixes §1.5). One commit,
   adds a schema test for the new changeset, removes the
   `update_all` write.
2. **§1.3 — drop the per-event `list_templates_from_db/0` re-read in
   `set_template_language`.** Trivial — replace with an in-place
   `Map.put` over the `:templates` assign.

The Firefox compat work (§1.1) is bigger — probably its own issue,
and worth deciding scope before opening (JS fallback vs. Floating UI
vs. document as Chromium-only). I'd rather not bundle it here.

§1.4 / §1.6 / §1.7 are NITs — happy to leave them or sweep them in
the next PR.

Let me know and I'll send the §1.2 + §1.3 follow-up.

---

## 4. Things to consider for next PR

- **Languages-module change broadcasts.** §1.6 — if the Languages
  module ever starts emitting a settings-changed pubsub event,
  subscribe to it on the documents LV and refresh `:enabled_languages`
  on the message. Closes the "newly-enabled language doesn't appear
  until refresh" gap. Not worth coordinating across the two repos
  for this PR.
- **Document language inheritance in the consumer API.** PR text
  says "documents inherit language from their template's row" but
  there's no explicit `Documents.get_document_language/1` or
  equivalent — consumers have to manually
  `Documents.list_documents_from_db()` → look up `template_uuid` →
  query templates. Worth a single helper:
  `get_template_language_for_document(google_doc_id)` returning
  `{:ok, code | nil}`, with the `nil`-template-uuid case explicitly
  documented.
- **Audit-log volume for `template.language_updated`.** Setting a
  language is a low-frequency action so this is fine, but if the
  picker grows a "set all" bulk action, the activity feed will fill
  with N rows. Worth a future `template.language_bulk_updated`
  variant if/when that ships.
- **Move `@uuid_pattern` to a shared helper module.** Carried over
  from the PR #12 review (still duplicated between
  `phoenix_kit_document_creator.ex` and `google_docs_client.ex`).
  Trivial, just hasn't happened yet.
- **Tag the popover compat as a known limitation in AGENTS.md** even
  if §1.1 doesn't get fixed in the immediate follow-up. "CSS Anchor
  Positioning required for the templates language picker; Firefox
  users will see the popover render unanchored" is the kind of thing
  future-you will appreciate finding in AGENTS.md.

---

## 5. Verification

- **`mix precommit`**: clean (compile, format, credo --strict,
  dialyzer 0 errors)
- **`mix test`** against local path-dep `phoenix_kit`: 414 tests, 0
  failures, 4 excluded — confirmed against the PR's claim. CI will
  remain red until `phoenix_kit#515` publishes 1.7.105 (expected,
  not actionable here).
- **Test surface added** (per author summary, all confirmed):
  - 6 schema tests for the V110 `:language` field
    (`test/schemas/template_test.exs:208-238`)
  - 9 integration tests for `update_template_language/3`
    (`test/integration/documents_test.exs:691-794`)
  - 3 LV tests for the `set_template_language` event
    (`test/phoenix_kit_document_creator/web/documents_live_test.exs:625-716`)
  - 1 schema test pinning that `sync_changeset/2` does NOT cast
    `:language` (regression guard)
  - 1 new `active_integration_test.exs` test for the §1.2
    no-exact-match clear path; 2 existing tests retrofitted to match
    the new symmetric behavior
  - `Test.StubIntegrations.get_integration/1` now returns the seeded
    connection's `data` map (closes the prior degenerate-stub
    short-circuit)
- **PR-#11 / PR-#12 parking-lot residuals (M1, M2, S2, S3, S5, §1.2,
  §1.3, §1.7, §1.9)** — all closed mechanically per the author's
  list; the FOLLOW_UP files are now after-action reports rather than
  open TODO lists, which is what
  `feedback_followup_is_after_action.md` calls for.
- **Browser smoke noted as "0 console errors" on `phoenix_kit_parent`**
  — likely covered Chromium only. See §1.1.

---

*Review notes captured by Claude Opus 4.7 with `elixir-thinking`,
`phoenix-thinking`, `ecto-thinking`, and `otp-thinking` skills loaded.*
