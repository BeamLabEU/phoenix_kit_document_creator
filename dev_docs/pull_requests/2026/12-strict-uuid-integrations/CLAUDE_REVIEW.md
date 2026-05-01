# PR #12 Review — Strict-UUID Integrations + Phase 2 sweep + test shim removal

**Author:** Max Don (`mdon`)
**Reviewer:** Dmitri + Claude (Opus 4.7)
**Merged:** 2026-05-01
**Range:** `4d3633b..36473fa` — 7 commits, +1046/-452 across 15 files

## TL;DR

Solid work overall. The strict-UUID flip is the right move and the lazy on-read
promotion + boot-time sweep is a clean two-layered migration. Test infra
cleanup (drop the hand-rolled migration shim, run core's versioned migrations)
is exactly what we wanted. **One real security finding** (legacy plaintext
secrets persist after migration), a handful of code-quality nits, and one
behavioral edge case worth a follow-up commit. None of these block — they're
post-merge polish.

---

## 1. Findings

### 1.1 [SECURITY — must fix] Legacy OAuth secrets are not cleared after migration

**Where:** `lib/phoenix_kit_document_creator.ex:238-270` (`do_migrate_oauth_credentials/1`)

After a successful migration the new integration row is created, but the
**original `document_creator_google_oauth` settings row is left intact** —
including the cleartext `client_secret`, `access_token`, and `refresh_token`.

```elixir
with {:ok, %{uuid: uuid}} <- ensure_connection(...),
     {:ok, _saved} <- Integrations.save_setup(uuid, integration_data) do
  migrate_legacy_folders(legacy_data)
  log_migration_activity(...)
  Logger.info(...)
  :migrated      # ← legacy key never cleared
else
  ...
end
```

The `already_migrated?/0` check stops re-migration on subsequent boots, so the
legacy row just sits there forever holding plaintext secrets. The whole point
of moving to `PhoenixKit.Integrations` is centralizing (and presumably
encrypting) credential storage — leaving cleartext copies in `phoenix_kit_settings`
defeats that.

**Suggested fix:** after the activity log emission, null the legacy key:

```elixir
Settings.update_json_setting_with_module(
  @legacy_oauth_settings_key,
  %{},  # or call a delete API if Settings has one
  module_key()
)
```

Wrap it in a `rescue` — if the cleanup fails the migration is still successful,
just log a warning so ops can clean up by hand. We have similar shape on
`migrate_legacy_folders/1` already.

I'm happy to push this fix here directly — see §3.

---

### 1.2 [MEDIUM] Inconsistent fallback semantics: boot path vs lazy path for bare `"google"`

**Where:**
- Boot: `lib/phoenix_kit_document_creator.ex:420-449` (`resolve_via_list_connections/1`)
- Lazy: `lib/phoenix_kit_document_creator/google_docs_client.ex:97-125` (`migrate_legacy_connection/1`)

The boot-time sweep and the lazy on-read migration handle the bare `"google"`
case differently:

| Input  | Boot (`resolve_via_list_connections/1`) | Lazy (`migrate_legacy_connection/1`) |
|--------|------------------------------------------|---------------------------------------|
| `"google:personal"` | matches `name == "personal"` → uuid     | matches → uuid                        |
| `"google"`          | parses as `("google", "default")`, scans for `name == "default"` → if no row named "default", `{:error, :not_found}` and the setting is **not** rewritten | falls through `get_integration` failure → picks **first row** from `list_connections` and persists it |

So a system upgraded with `google_connection = "google"` will:
- have the boot pass log `cannot resolve 'google'` and leave the legacy string in place
- on the next request, get the lazy path which silently picks an arbitrary first connection

It works, but the behavior asymmetry is surprising and the lazy path's
"silently pick whatever's first" is the foot-gun half of the legacy compat
chain. If a user has two Google accounts connected, which one becomes "the
active one" depends on insert order — non-deterministic from their POV.

**Suggested:** make the boot path mirror the lazy path's first-row fallback so
they agree, OR make the lazy path stricter (clear the setting + log, force
re-pick) so neither silently chooses. I lean toward the latter — silent
auto-selection of credentials is the kind of thing that produces "why is my
template showing the wrong account" tickets six months later.

---

### 1.3 [LOW] `already_migrated?/0` queries via legacy string key

**Where:** `lib/phoenix_kit_document_creator.ex:229-236`

```elixir
defp already_migrated? do
  case Integrations.get_integration("#{@new_integration_provider}:#{@new_integration_name}") do
    {:ok, _} -> true
    _ -> false
  end
end
```

This uses the `provider:name` string-key form of `get_integration/1`. The PR
narrative is that we're moving toward strict-UUID; `find_uuid_by_provider_name/1`
is the cleaner V107 primitive used elsewhere in the new code. As-is, this
check depends on core continuing to support string-key lookup as a back-compat
shim — fine today, but couples the migration's "did this already run" check
to a path the rest of the strict-UUID work wants to deprecate.

**Suggested:** switch to `find_uuid_by_provider_name({provider, name})` once the
floor version is bumped. Low priority — works fine.

---

### 1.4 [LOW] `migrate_legacy/0` `with` block is a no-op pattern

**Where:** `lib/phoenix_kit_document_creator.ex:181-200`

```elixir
def migrate_legacy do
  {credentials_result, references_result} =
    with creds_result <- migrate_legacy_oauth_credentials(),
         refs_result <- migrate_legacy_connection_references() do
      {creds_result, refs_result}
    end

  {:ok, %{credentials_migration: credentials_result, reference_migration: references_result}}
rescue
  ...
end
```

`with` without an `else` and without `{:ok, _}`/`{:error, _}` short-circuit
patterns is just two assignments. Both calls already have their own `rescue`
clauses so the outer `with` adds nothing. Reads cleaner as:

```elixir
def migrate_legacy do
  creds_result = migrate_legacy_oauth_credentials()
  refs_result = migrate_legacy_connection_references()
  {:ok, %{credentials_migration: creds_result, reference_migration: refs_result}}
rescue
  e -> ...
end
```

Pure style nit, but the `with` here pattern-matches as "I'm doing something
with short-circuit semantics" when you're not — that mismatch is what the
elixir-thinking skill flags as worth fixing.

---

### 1.5 [LOW] `uuid_shape?` regex doesn't actually enforce UUIDv7

**Where:**
- `lib/phoenix_kit_document_creator.ex:391-393`
- `lib/phoenix_kit_document_creator/google_docs_client.ex:42-45` (same regex, separate copy)

```elixir
@uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
```

Comment claims this matches "a UUIDv7-shaped string" but the regex accepts any
RFC 4122 shape (v1–v8). For a strict UUIDv7 check the third group must start
with `7`:

```elixir
~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
```

Either tighten the regex to match the doc, or relax the doc to "any UUID-shaped
string". The relaxed form is fine in practice (the only thing this guards
against is mis-classifying a legacy `"google:name"` as a uuid) — but the comment
should match what the code does.

Also: defining the same regex twice in two modules is a maintenance smell.
Move it to a shared helper.

---

### 1.6 [LOW] Variable named `uuid` actually holds a possibly-legacy string

**Where:** `lib/phoenix_kit_document_creator/google_docs_client.ex:80-88`

```elixir
def active_integration_uuid do
  case Settings.get_json_setting(@settings_key, %{}) do
    %{"google_connection" => uuid} when is_binary(uuid) ->
      if uuid?(uuid), do: uuid, else: migrate_legacy_connection(uuid)
    _ ->
      nil
  end
end
```

The match binds the value to `uuid`, but at that point it might be `"google"`,
`"google:personal"`, or a real uuid. Reading the body, `migrate_legacy_connection(uuid)`
expects a legacy string — so the name lies until the `uuid?/1` check passes.

Tiny rename improves readability:

```elixir
%{"google_connection" => stored} when is_binary(stored) ->
  if uuid?(stored), do: stored, else: migrate_legacy_connection(stored)
```

---

### 1.7 [INFO] Lazy on-read writes mutate the DB during GET requests

**Where:** `lib/phoenix_kit_document_creator/google_docs_client.ex:150-178` (`rewrite_setting/1`)

`active_integration_uuid/0` runs on every Drive/Docs request. When legacy data
is still in `document_creator_settings`, the read path also performs a settings
write to promote the value to uuid form. This is documented in the comment and
the rescue block protects against transient DB failures, but worth flagging
for two reasons:

1. **Read replicas:** if any deployment shape ever serves reads from a replica,
   this code path will fail until promoted by something on the primary.
   Currently fine — just record the constraint somewhere.
2. **Audit log noise:** `Settings.update_json_setting_with_module/3` may emit
   activity entries on every legacy-shape request until promoted. Boot-time
   sweep mostly drains this, but for a host that doesn't call
   `run_all_legacy_migrations/0`, every request from every user generates a
   write+log until done. README says boot is optional with the lazy fallback;
   maybe stronger phrasing like "strongly recommended" would steer users right.

---

### 1.8 [INFO] Three failing tests on `mix test` against Hex `~> 1.7`

The PR description acknowledges "393 tests, 3 pre-existing Hex-shape failures"
in `active_integration_test.exs`. They're pinned to the unpublished
`add_connection/3` return-shape change in core. Fine for now since the
canonical channel is `phoenix_kit_parent` (path-dep override), but **the
failing tests are not marked** — `mix test` against the standalone module
exits non-zero, which means CI will fail and contributors will think they
broke something.

**Suggested:** add `@tag :requires_unreleased_core` (or similar) on the three
specific tests and exclude that tag from the standalone run via
`test_helper.exs`. Track removal of the tag with a TODO referencing the core
release that publishes the new shape. Without a tag, the "this is expected"
context lives in the PR body and gets lost.

---

### 1.9 [INFO] Test stub uses `:named_table` ETS — implicit global

**Where:** `test/support/stub_integrations.ex:25,173-178`

```elixir
@ets_table :pkdc_stub_integrations
...
defp ensure_table do
  case :ets.info(@ets_table) do
    :undefined -> :ets.new(@ets_table, [:set, :public, :named_table])
    _ -> :ok
  end
end
```

A `:named_table` is global to the BEAM. Two test modules using this stub
concurrently would clobber each other's state. The integration test correctly
declares `async: false`, but the constraint is invisible from the stub's
shape — if someone copies the stub or adds a second consumer, async coupling
becomes a flaky-test source.

**Suggested (optional):** key the table by `self()` or `start_link` it per-test
under the test's owner pid. Today's usage is fine; this is forward-looking.

---

### 1.10 [INFO / Already noted in FOLLOW_UP] Error-path activity logging gap

The "Findings explicitly NOT addressed" section in the PR body calls out that
boot migrators only log activity on the success path. That is correct and
worth tracking as a cross-module follow-up — flagging here for visibility, not
as a complaint.

---

## 2. What landed well

These are worth calling out so they keep happening:

- **Two-layered migration (boot + lazy fallback)** is the right shape. Boot
  drains 99% of the work; lazy keeps things working for hosts that don't wire
  `run_all_legacy_migrations/0`. Idempotency is well-tested.
- **`integrations_backend/0` config indirection** for the Integrations
  dispatch is small, has one clear purpose (test routing), and doesn't infect
  production code. This is the right way to do testable third-party calls in
  Elixir — way better than wrapping in a GenServer or building a behaviour.
- **`Logger.warning` rescues with `e.__struct__` (no `Exception.message/1`)**
  to avoid leaking provider strings or query bindings out of Ecto exception
  structs — that's a non-obvious detail the original C12 review caught and the
  fix is consistent across all four rescue sites. Memorialize this pattern in
  AGENTS.md as a project convention.
- **Test migration shim removal** is a strict win. The 180-line hand-rolled
  DDL was always going to drift from core; running
  `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, all: true)`
  is the same call hosts make in production, so test setup tracks reality.
- **`@version` derived from `Mix.Project.config()[:version]`** at compile time
  closes the version-drift bug for good. Smart fix.
- **SSRF redirect-block hardening** with `redirect: false` prepended via
  `Keyword.get/2`'s first-match semantics is exactly the kind of detail that's
  easy to miss — the comment explaining why `:req_options` can't override it
  is excellent.
- **`phx-disable-with` on browse-folder buttons** — small UX win; double-click
  no longer spawns concurrent `Task.start_link` calls.
- **The README section explaining `active_integration_uuid/0` + `migrate_legacy/0`**
  closes a documentation gap. Consumers who read only the README can now
  understand the storage shape without grepping AGENTS.md.

---

## 3. What I'd like to fix in this branch

If you're OK with it, I'd push two follow-up commits on top of the merge:

1. **§1.1 — clear legacy OAuth key after successful migration.** Real security
   finding; quick fix, additive test.
2. **§1.4 — drop the no-op `with` in `migrate_legacy/0`.** Pure simplification.

The rest (§1.2 through §1.9) I'd leave alone for now or open separate issues
— most are LOW severity and the §1.2 fallback question deserves discussion
before we change behavior.

Let me know and I'll send those two as a small follow-up commit.

---

## 4. Things to consider for next PR

- **Move `@uuid_pattern` to a shared helper module** so the regex isn't
  duplicated between `phoenix_kit_document_creator.ex` and
  `google_docs_client.ex`.
- **Reconsider lazy-path silent first-row pick** (§1.2). Better UX to surface
  "we couldn't auto-resolve, please pick a connection" than to silently choose
  one. Could land as part of the next sweep.
- **Tag the three Hex-mismatch failing tests** so the standalone `mix test`
  run is green again.
