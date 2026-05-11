# Image Tag Support — Design Spec

**Status:** Draft (brainstormed 2026-05-11)
**Owner:** Document Creator module (`phoenix_kit_document_creator`)
**Scope:** Add image placeholders to templates, detection of those placeholders, and a media-picking UI to fill them when a document is generated.

---

## 1. Goal

Today templates support only textual variables — `{{ name }}` — substituted via the Google Docs `replaceAllText` request. We want templates to also support **image placeholders** that the operator fills with one or more uploaded media files at document-generation time.

Two new placeholder shapes:

- `{{ image: name }}` — exactly one image
- `{{ images: name }}` — an ordered list of images

Existing `{{ name }}` text behaviour is unchanged.

## 2. Non-goals (first iteration)

The following were considered and explicitly deferred:

- **Placeholder-image approach** (drop an image into the template, identify by alt-text, replace via `ReplaceImage`). Rejected after analysis: gives free formatting preservation for single images but the Google Docs API has no `DuplicateInlineObject` request, so the multi-image case requires `InsertInlineImage + UpdateImageProperties` anyway. Using the placeholder-image only for the single case would have made `{{ image }}` and `{{ images }}` follow different code paths for no real benefit.
- **In-tag DSL** like `{{ image: photos width=200 sep=newline }}`. All non-name parameters live in the admin UI / DB, parallel to how `:date` / `:currency` are configured today.
- **Per-upload overrides** of size, caption, border, recolor, rotation.
- **Borders / recolor / rotation / wrap modes** on inserted images — Google's `InsertInlineImage` does not accept these, and we are not chaining an `UpdateImageProperties` call in this iteration.
- **Auto-table layout for galleries.** May come later if explicitly requested.
- **Image captions.** Separate feature.
- **Resizing / compression / format conversion of uploads.** That is PhoenixKit Media's responsibility.

## 3. Tag syntax and detection

### 3.1 Regex

Text-variable detection regex stays as `~r/\{\{\s*(\w+)\s*\}\}/` (already cannot match image tags because `\w+` does not consume `:`), but we add a **deliberate** negative-lookahead guard so the invariant is encoded, not accidental:

```elixir
@text_var_regex ~r/\{\{\s*(?!images?\s*:)(\w+)\s*\}\}/
```

Image-variable regex:

```elixir
@image_var_regex ~r/\{\{\s*(image|images)\s*:\s*(\w+)\s*\}\}/
```

Variable names: `\w+` (letters, digits, underscore), unchanged from text.

### 3.2 Detection API

The existing `PhoenixKitDocumentCreator.Variable.extract_variables/1` is split:

| Function | Returns |
|---|---|
| `extract_string_variables/1` | `[String.t()]` — list of distinct text variable names |
| `extract_image_variables/1` | `[%{name: String.t(), kind: :image \| :image_list}]` |
| `extract_variables/1` | `%{text: [String.t()], image: [%{name, kind}]}` — convenience fork that calls both |

`extract_variables/1` is the public entry point; both leaf functions are public so callers can ask for one side only.

`Documents.detect_variables/1` (Drive-aware wrapper) returns `{:ok, %{text: [...], image: [...]}}` instead of `{:ok, [string]}`. All current callers must be updated; this is treated as an intentional breaking change inside this module's public API.

## 4. Data model

### 4.1 Variable struct

```elixir
@type variable_type :: :text | :date | :currency | :multiline | :image | :image_list

%PhoenixKitDocumentCreator.Variable{
  name: String.t(),
  label: String.t(),
  type: variable_type(),
  default: String.t() | nil,
  required: boolean(),
  config: map()                # NEW field; empty for text variables
}
```

`config` shape for image types:

```elixir
# :image
%{default_width_px: 400}

# :image_list
%{
  default_width_px: 400,
  separator: :newline,         # :newline | :space | :none
  max_count: nil               # integer or nil
}
```

`default_width_px` is required for both image types; height is computed from the chosen media's aspect ratio at render time. EMU conversion (`px * 9525`) happens at the Google API boundary.

### 4.2 Storage

No new tables. The existing `phoenix_kit_doc_templates.variables` jsonb column gains the new shape. The existing `phoenix_kit_doc_documents.variable_values` jsonb column stores image values as media IDs:

```elixir
# Text variable
"client_name" => "Acme Corp"

# Single image variable
"logo" => %{"media_id" => "<phoenix_kit media uuid>"}

# Image list variable
"photos" => %{"media_ids" => ["<uuid-1>", "<uuid-2>", "<uuid-3>"]}
```

Media IDs are stable across renaming. If a referenced media is deleted, rendering returns `:image_not_found`.

## 5. Media picking UI (media asking)

We reuse PhoenixKit's existing `MediaBrowser` LiveComponent via its selector pattern (`PhoenixKitWeb.Helpers.MediaSelectorHelper`). No new media UI is built.

- `:image` field → button "Choose image" → opens `MediaBrowser` in **single-select** mode → returns one `media_id`.
- `:image_list` field → button "Choose images" → opens `MediaBrowser` in **multi-select** mode → returns ordered array of `media_id`s, with reorder/remove controls in the calling form.

The admin form for editing a template variable's `config` (default width, separator, max_count) is a separate small form rendered alongside the existing variable-edit UI.

## 6. Substitution pipeline

Document generation orchestrates **two ordered Google Docs `batchUpdate` calls** against the copied document:

### Pass 1 — text variables (unchanged)

`replaceAllText` for every text variable currently filled in `variable_values`. Image tags are left untouched because the text regex deliberately excludes them.

### Pass 2 — image variables

For each filled image variable (`media_id` non-nil or `media_ids` non-empty):

1. `documents.get` the copy → walk `body.content` (and table cells / headers / footers) to find every `{{ image: name }}` or `{{ images: name }}` occurrence; record `(startIndex, endIndex)` of each.
2. Resolve `media_id`(s) → public signed URLs via PhoenixKit Media; fetch each media's natural `(width_px, height_px)` so we can derive `objectSize.height = default_width_px / aspect_ratio`.
3. Build a single `batchUpdate` body. For each occurrence, sorted by **descending** `startIndex` (so earlier insertions do not shift later ones):
   - `DeleteContentRange{startIndex, endIndex}` — remove the textual tag.
   - For `:image`: one `InsertInlineImage{location: startIndex, uri, objectSize: {width, height}}`.
   - For `:image_list`: a sequence at `startIndex` that interleaves `InsertInlineImage` and `InsertText{separator}`. Because requests at the same index are applied in submission order and each shifts the index, the sequence is built so that the **last** media in the list is inserted **first**, ensuring visual order matches array order. Separator inserts go between adjacent images only (not before first, not after last).
4. Issue one `batchUpdate` for the whole pass.

### Empty-value handling

If an image variable is required but empty → return `{:error, :missing_required_value}` before rendering, mirroring text-variable behaviour.

If an image variable is **optional and empty** → still emit a `DeleteContentRange` for every occurrence of its tag (so the document does not contain a literal `{{ image: x }}` string). This is the "очищать отдельно" behaviour the regex isolation enables.

### Ordering invariant

Pass 1 (text) **must complete** before Pass 2 (images) starts. The image pass relies on the indices it observes via `documents.get`, and `replaceAllText` from Pass 1 can shift those indices. We do not interleave them in a single batch.

## 7. Errors

Added to `PhoenixKitDocumentCreator.Errors.message/1`:

| Atom | Meaning |
|---|---|
| `:image_not_found` | `variable_values` references a media_id that no longer exists |
| `:image_url_not_public` | media URL fails Google's URI constraints (not https, > 2 KB, or unreachable) |
| `:image_too_large` | media exceeds Google's 50 MB / 25 Mpx limit |
| `:image_insert_failed` | image-pass `batchUpdate` returned an error |
| `:image_tag_not_found` | a filled image variable has no corresponding tag in the document (template drift) |
| `:missing_required_value` | a required text or image variable is unfilled |

All atoms get a literal `gettext("…")` clause; translations live in core `phoenix_kit`.

## 8. Code layout changes

| File | Change |
|---|---|
| `lib/phoenix_kit_document_creator/variable.ex` | Split detection; add `:image` / `:image_list` types; add `config` field; add `extract_string_variables/1`, `extract_image_variables/1`; rework `extract_variables/1` to return forked map; update `build_definitions/1` |
| `lib/phoenix_kit_document_creator/documents.ex` | Update `detect_variables/1` contract; rework `create_document_from_template/3` to orchestrate two passes; add resolution of media_ids → URLs + dimensions |
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | Add `substitute_images/2` (or similar) that takes `(file_id, [%{tag_name, kind, urls_with_sizes, separator, default_width_px}])` and performs `documents.get` + builds the image batch |
| `lib/phoenix_kit_document_creator/errors.ex` | New atoms + gettext entries |
| `lib/phoenix_kit_document_creator/web/...` | Admin form fields for `config`; MediaBrowser-backed input components for `:image` / `:image_list` in the variable-fill form |
| `test/phoenix_kit_document_creator/variable_test.exs` | Cover both regexes; **explicit test that text regex does NOT capture `{{ image: x }}` or `{{ images: x }}`** |
| `test/phoenix_kit_document_creator/documents_test.exs` | Cover detect fork output |
| Integration test on dev Google account | End-to-end: template with mixed tags → fill → generated doc has substitutions + inserted images |

## 9. Risks and open questions

- **MediaBrowser URL stability.** This spec assumes PhoenixKit Media exposes a stable, public, HTTPS, ≤ 2 KB signed URL for each media item. To be verified during implementation; if not, a small thin URL-mint helper is added inside this module.
- **Media dimensions in PhoenixKit Media.** Assumes width/height are stored at upload time. If they are not, the image pass either falls back to `objectSize` with width-only (Google then uses natural aspect — acceptable degradation) or we add a one-shot dimension probe.
- **Image tag inside a table cell, header, or footer.** Substitution must traverse all of `body.content`, `headers`, `footers`, table cell contents. Test coverage required.
- **Same tag appearing multiple times.** The pipeline already handles this — each occurrence becomes its own DeleteContentRange + InsertInlineImage(s). Confirmed not a special case.

## 10. Decisions recorded

| # | Decision | Rationale |
|---|---|---|
| D1 | Text tag with explicit `image:` / `images:` keyword, not placeholder-image | Multi-image case requires re-insertion anyway; placeholder approach saves nothing in that case and forces two code paths. |
| D2 | Parameters in admin UI / DB, not in tag | Authors are not programmers; mirrors existing `:date`/`:currency` story. |
| D3 | Media via PhoenixKit MediaBrowser | Component exists; selection mode is built-in for single + multi. |
| D4 | Newline separator default, configurable per variable | Covers both stacked and inline use cases without complicating the UI. |
| D5 | Default width in admin + aspect ratio from media | Predictable, prevents 4000×3000 photos from blowing up the page. |
| D6 | Store `media_id` in `variable_values`, not URL | Stable across renames; URL freshness handled at render. |
| D7 | Two-pass batchUpdate (text first, images second) | `replaceAllText` shifts indices that the image pass relies on. |
| D8 | Text regex deliberately excludes `image:` / `images:` via negative-lookahead | Encodes the invariant rather than relying on `\w+` not eating `:`. |
| D9 | Refactor `extract_variables/1` to return forked `%{text:, image:}`; keep `extract_string_variables/1` + `extract_image_variables/1` as public leaves | Caller convenience without losing single-side access. |
