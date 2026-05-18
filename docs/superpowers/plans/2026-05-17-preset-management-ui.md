# Preset Management UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an admin UI to manage template presets per document category on the existing `CategoriesLive` page, with no database migrations.

**Architecture:** A full-width "Presets" panel is added below the Categories/Types columns on `CategoriesLive`, listing the selected category's presets grouped by type. Create/edit happens on a dedicated `PresetFormLive` (routed, like `CategoryFormLive`) with a drag-reorder section editor. Category and type association is stored by repurposing the existing `scope_id` (category uuid) and `scope_type` (type uuid) string fields on `TemplatePreset`.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, DaisyUI, Gettext. Tests use `PhoenixKitDocumentCreator.DataCase` (context) and `PhoenixKitDocumentCreator.LiveCase` (LiveView).

**Spec:** `docs/superpowers/specs/2026-05-17-preset-management-ui-design.md`

---

## File Structure

- Modify: `lib/phoenix_kit_document_creator/schemas/template_preset.ex` — document the `scope_*` convention in moduledoc.
- Modify: `lib/phoenix_kit_document_creator/documents.ex` — add `update_preset/2`, `delete_preset/1`, `preset_stale_info/1`.
- Modify: `lib/phoenix_kit_document_creator/web/routes.ex` — add `PresetFormLive` routes.
- Create: `lib/phoenix_kit_document_creator/web/preset_form_live.ex` — new/edit form + section editor.
- Modify: `lib/phoenix_kit_document_creator/web/categories_live.ex` — add the Presets panel.
- Modify: `priv/gettext/{en,et,ru}/LC_MESSAGES/default.po` — translations.
- Create: `test/documents/preset_management_test.exs` — context tests.
- Create: `test/phoenix_kit_document_creator/web/preset_form_live_test.exs` — form tests.
- Modify: `test/phoenix_kit_document_creator/web/categories_live_test.exs` — panel tests.

---

## Task 1: Document the storage convention

**Files:**
- Modify: `lib/phoenix_kit_document_creator/schemas/template_preset.ex:1-17`

- [ ] **Step 1: Update the moduledoc**

Replace the `scope_type` / `scope_id` paragraph in the moduledoc with:

```elixir
  @moduledoc """
  Schema for named, reusable template compositions.

  A preset captures an ordered list of section descriptors (template uuid,
  position, variable defaults, image params) that can be applied to a new
  document to produce a multi-section composition in one step.

  ## Scope convention (Stage 1, no migration)

  Presets are associated with the document taxonomy by repurposing the
  generic scope pair:

    * `scope_id`   — owning Category uuid (always set for managed presets)
    * `scope_type` — owning Type uuid, or `nil` for category-wide presets

  A future migration will replace this with real `category_uuid` /
  `type_uuid` foreign keys (see the design spec).

  The `sections` field is a JSONB array where each element is a map
  describing one section (keys: `template_uuid`, `position`,
  `variable_values`, `image_params`). Image substitution is restricted to
  PNG, JPEG, and GIF formats; enforcement happens at the context layer.
  """
```

- [ ] **Step 2: Commit**

```bash
git add lib/phoenix_kit_document_creator/schemas/template_preset.ex
git commit -m "docs(presets): document scope_id/scope_type taxonomy convention"
```

---

## Task 2: Context — `update_preset/2` and `delete_preset/1`

**Files:**
- Modify: `lib/phoenix_kit_document_creator/documents.ex` (preset section, ~line 2048)
- Test: `test/documents/preset_management_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/documents/preset_management_test.exs`:

```elixir
defmodule PhoenixKitDocumentCreator.Documents.PresetManagementTest do
  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.{Template, TemplatePreset}

  defp insert_template!(status \\ "published") do
    unique = System.unique_integer([:positive])

    {:ok, template} =
      %Template{}
      |> Template.changeset(%{
        name: "Template #{unique}",
        google_doc_id: "tmpl-#{unique}",
        status: status
      })
      |> Repo.insert()

    template
  end

  defp insert_preset!(attrs) do
    base = %{name: "Preset", created_by_uuid: Ecto.UUID.generate()}
    {:ok, preset} = Documents.save_preset(Map.merge(base, attrs))
    preset
  end

  describe "update_preset/2" do
    test "updates name, description and sections" do
      preset = insert_preset!(%{name: "Old", scope_id: Ecto.UUID.generate()})

      assert {:ok, updated} =
               Documents.update_preset(preset, %{
                 name: "New",
                 description: "Desc",
                 sections: [%{"template_uuid" => nil, "position" => 0}]
               })

      assert updated.name == "New"
      assert updated.description == "Desc"
      assert length(updated.sections) == 1
    end

    test "returns error changeset for blank name" do
      preset = insert_preset!(%{name: "Old"})
      assert {:error, %Ecto.Changeset{}} = Documents.update_preset(preset, %{name: ""})
    end
  end

  describe "delete_preset/1" do
    test "removes the preset" do
      preset = insert_preset!(%{name: "Doomed"})
      assert {:ok, _} = Documents.delete_preset(preset)
      assert Repo.get(TemplatePreset, preset.uuid) == nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/documents/preset_management_test.exs`
Expected: FAIL — `update_preset/2` and `delete_preset/1` are undefined.

- [ ] **Step 3: Implement the functions**

In `lib/phoenix_kit_document_creator/documents.ex`, immediately after `save_preset/1`:

```elixir
  @doc """
  Updates an existing preset from `attrs`.
  """
  @spec update_preset(TemplatePreset.t(), map()) ::
          {:ok, TemplatePreset.t()} | {:error, Ecto.Changeset.t()}
  def update_preset(%TemplatePreset{} = preset, attrs) do
    preset |> TemplatePreset.changeset(attrs) |> repo().update()
  end

  @doc """
  Permanently deletes a preset (hard delete — no trash in Stage 1).
  """
  @spec delete_preset(TemplatePreset.t()) ::
          {:ok, TemplatePreset.t()} | {:error, Ecto.Changeset.t()}
  def delete_preset(%TemplatePreset{} = preset) do
    repo().delete(preset)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/documents/preset_management_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/documents.ex test/documents/preset_management_test.exs
git commit -m "feat(presets): add update_preset/2 and delete_preset/1"
```

---

## Task 3: Context — `preset_stale_info/1`

A preset is stale when a section references a template that is missing, or whose `status` is `trashed` or `lost`.

**Files:**
- Modify: `lib/phoenix_kit_document_creator/documents.ex` (after `delete_preset/1`)
- Test: `test/documents/preset_management_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside `test/documents/preset_management_test.exs`, before the final `end`:

```elixir
  describe "preset_stale_info/1" do
    test "flags sections with missing or trashed templates" do
      ok = insert_template!("published")
      trashed = insert_template!("trashed")
      missing_uuid = Ecto.UUID.generate()

      preset =
        insert_preset!(%{
          sections: [
            %{"template_uuid" => ok.uuid, "position" => 0},
            %{"template_uuid" => trashed.uuid, "position" => 1},
            %{"template_uuid" => missing_uuid, "position" => 2}
          ]
        })

      info = Documents.preset_stale_info(preset)

      assert info.broken_count == 2
      assert MapSet.new(info.broken_template_uuids) ==
               MapSet.new([trashed.uuid, missing_uuid])
    end

    test "reports zero for an all-published preset" do
      ok = insert_template!("published")
      preset = insert_preset!(%{sections: [%{"template_uuid" => ok.uuid, "position" => 0}]})

      assert Documents.preset_stale_info(preset).broken_count == 0
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/documents/preset_management_test.exs`
Expected: FAIL — `preset_stale_info/1` is undefined.

- [ ] **Step 3: Implement the function**

In `documents.ex`, after `delete_preset/1`:

```elixir
  @doc """
  Returns staleness info for a preset.

  A section is "broken" when its `template_uuid` references a template that
  no longer exists, or whose `status` is `trashed` or `lost`.

  Returns `%{broken_count: non_neg_integer(), broken_template_uuids: [binary()]}`.
  """
  @spec preset_stale_info(TemplatePreset.t()) :: %{
          broken_count: non_neg_integer(),
          broken_template_uuids: [binary()]
        }
  def preset_stale_info(%TemplatePreset{sections: sections}) do
    referenced =
      sections
      |> Enum.map(&Map.get(&1, "template_uuid"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    healthy =
      Template
      |> where([t], t.uuid in ^referenced and t.status not in ["trashed", "lost"])
      |> select([t], t.uuid)
      |> repo().all()
      |> MapSet.new()

    broken = Enum.reject(referenced, &MapSet.member?(healthy, &1))

    %{broken_count: length(broken), broken_template_uuids: broken}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/documents/preset_management_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/documents.ex test/documents/preset_management_test.exs
git commit -m "feat(presets): add preset_stale_info/1 broken-template detection"
```

---

## Task 4: Routes for `PresetFormLive`

**Files:**
- Modify: `lib/phoenix_kit_document_creator/web/routes.ex`

- [ ] **Step 1: Add localized routes**

In `admin_locale_routes/0`, inside the `quote do`, after the type routes:

```elixir
      live(
        "/admin/document-creator/categories/:category_uuid/presets/new",
        PhoenixKitDocumentCreator.Web.PresetFormLive,
        :new,
        as: :doc_creator_preset_new_localized
      )

      live(
        "/admin/document-creator/presets/:uuid/edit",
        PhoenixKitDocumentCreator.Web.PresetFormLive,
        :edit,
        as: :doc_creator_preset_edit_localized
      )
```

- [ ] **Step 2: Add non-localized routes**

In `admin_routes/0`, inside the `quote do`, after the type routes:

```elixir
      live(
        "/admin/document-creator/categories/:category_uuid/presets/new",
        PhoenixKitDocumentCreator.Web.PresetFormLive,
        :new,
        as: :doc_creator_preset_new
      )

      live(
        "/admin/document-creator/presets/:uuid/edit",
        PhoenixKitDocumentCreator.Web.PresetFormLive,
        :edit,
        as: :doc_creator_preset_edit
      )
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: compiles (a warning about the missing `PresetFormLive` module is acceptable until Task 5; if `--warnings-as-errors` fails on it, run plain `mix compile`).

- [ ] **Step 4: Commit**

```bash
git add lib/phoenix_kit_document_creator/web/routes.ex
git commit -m "feat(presets): add PresetFormLive routes"
```

---

## Task 5: `PresetFormLive` — form with name, description, type

This task builds the form without the section editor (added in Task 6). The category is taken from the `:category_uuid` route param (new) or from `scope_id` (edit).

**Files:**
- Create: `lib/phoenix_kit_document_creator/web/preset_form_live.ex`
- Test: `test/phoenix_kit_document_creator/web/preset_form_live_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/phoenix_kit_document_creator/web/preset_form_live_test.exs`:

```elixir
defmodule PhoenixKitDocumentCreator.Web.PresetFormLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.{Documents, Taxonomy}

  defp setup_category(_) do
    {:ok, cat} = Taxonomy.create_category(%{name: "Legal"})
    {:ok, type} = Taxonomy.create_type(cat.uuid, %{name: "Contract"})
    %{cat: cat, type: type}
  end

  describe "new" do
    setup :setup_category

    test "creates a preset scoped to the category", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/presets/new")

      view
      |> form("form", preset: %{name: "Standard", description: "Default set"})
      |> render_submit()

      assert [preset] = Documents.list_presets(%{scope_id: cat.uuid})
      assert preset.name == "Standard"
      assert preset.scope_id == cat.uuid
    end
  end

  describe "edit" do
    setup :setup_category

    test "updates an existing preset", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, preset} =
        Documents.save_preset(%{
          name: "Old",
          scope_id: cat.uuid,
          created_by_uuid: Ecto.UUID.generate()
        })

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/presets/#{preset.uuid}/edit")

      view |> form("form", preset: %{name: "Renamed"}) |> render_submit()

      assert Documents.list_presets(%{scope_id: cat.uuid}) |> hd() |> Map.get(:name) ==
               "Renamed"
    end
  end
end
```

NOTE: confirm `Taxonomy.create_type/2` arity by checking `lib/phoenix_kit_document_creator/taxonomy.ex`; adjust the `setup_category` call if the signature differs.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/phoenix_kit_document_creator/web/preset_form_live_test.exs`
Expected: FAIL — `PresetFormLive` module does not exist.

- [ ] **Step 3: Create `PresetFormLive`**

Create `lib/phoenix_kit_document_creator/web/preset_form_live.ex`:

```elixir
defmodule PhoenixKitDocumentCreator.Web.PresetFormLive do
  @moduledoc """
  New / edit form for a Document Creator template preset.

  - New mode: `/admin/document-creator/categories/:category_uuid/presets/new`
  - Edit mode: `/admin/document-creator/presets/:uuid/edit`

  The category is fixed; the type is chosen from the category's types. The
  section editor (added in a later task) edits the `sections` JSONB array.
  """
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  require Logger

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.TemplatePreset
  alias PhoenixKitDocumentCreator.Taxonomy
  alias PhoenixKitDocumentCreator.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Preset"), mode: :new)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_path = URI.parse(uri).path || "/"

    socket =
      case params do
        %{"uuid" => uuid} ->
          preset = get_preset!(uuid)
          category = Taxonomy.get_category!(preset.scope_id)
          load(socket, :edit, preset, category, url_path)

        %{"category_uuid" => category_uuid} ->
          category = Taxonomy.get_category!(category_uuid)
          preset = %TemplatePreset{scope_id: category_uuid, sections: []}
          load(socket, :new, preset, category, url_path)
      end

    {:noreply, socket}
  end

  defp load(socket, mode, preset, category, url_path) do
    assign(socket,
      mode: mode,
      preset: preset,
      category: category,
      types: Taxonomy.list_types_for_category(category.uuid),
      form: to_form(TemplatePreset.changeset(preset, %{}), as: :preset),
      page_title: if(mode == :new, do: gettext("New Preset"), else: gettext("Edit Preset")),
      url_path: url_path
    )
  end

  defp get_preset!(uuid) do
    case Documents.get_preset(uuid) do
      nil -> raise Ecto.NoResultsError, queryable: TemplatePreset
      preset -> preset
    end
  end

  @impl true
  def handle_event("validate", %{"preset" => params}, socket) do
    changeset =
      socket.assigns.preset
      |> TemplatePreset.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :preset))}
  end

  def handle_event("save", %{"preset" => params}, socket) do
    params = build_params(params, socket)

    result =
      case socket.assigns.mode do
        :new -> Documents.save_preset(params)
        :edit -> Documents.update_preset(socket.assigns.preset, params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Preset saved."))
         |> push_navigate(to: Routes.path("/admin/document-creator/categories"))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save preset."))
         |> assign(form: to_form(changeset, as: :preset))}
    end
  end

  # Forces the scoping + actor fields the form must not control directly.
  defp build_params(params, socket) do
    type_uuid = blank_to_nil(params["scope_type"])

    params
    |> Map.put("scope_id", socket.assigns.category.uuid)
    |> Map.put("scope_type", type_uuid)
    |> Map.put_new("created_by_uuid", Helpers.actor_uuid(socket) || socket.assigns.preset.created_by_uuid)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6">
      <h1 class="text-2xl font-bold">
        {if @mode == :new, do: gettext("New Preset"), else: gettext("Edit Preset")}
      </h1>
      <p class="text-sm text-base-content/60">
        {gettext("Category")}: <span class="font-medium">{@category.name}</span>
      </p>

      <.form for={@form} phx-change="validate" phx-submit="save" class="flex flex-col gap-4">
        <div class="form-control">
          <label class="label"><span class="label-text">{gettext("Name")}</span></label>
          <input
            type="text"
            name="preset[name]"
            value={Phoenix.HTML.Form.input_value(@form, :name)}
            class="input input-bordered w-full"
          />
        </div>

        <div class="form-control">
          <label class="label"><span class="label-text">{gettext("Description")}</span></label>
          <textarea name="preset[description]" class="textarea textarea-bordered w-full">{Phoenix.HTML.Form.input_value(@form, :description)}</textarea>
        </div>

        <div class="form-control">
          <label class="label"><span class="label-text">{gettext("Document type")}</span></label>
          <select name="preset[scope_type]" class="select select-bordered w-full">
            <option value="">{gettext("Untyped")}</option>
            <%= for type <- @types do %>
              <option value={type.uuid} selected={@preset.scope_type == type.uuid}>
                {type.name}
              </option>
            <% end %>
          </select>
        </div>

        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
          <a href={Routes.path("/admin/document-creator/categories")} class="btn btn-ghost">
            {gettext("Cancel")}
          </a>
        </div>
      </.form>
    </div>
    """
  end
end
```

- [ ] **Step 4: Add the `get_preset/1` context helper**

In `documents.ex`, after `list_presets/1`:

```elixir
  @doc "Fetches a preset by uuid, or `nil`."
  @spec get_preset(binary()) :: TemplatePreset.t() | nil
  def get_preset(uuid), do: repo().get(TemplatePreset, uuid)
```

- [ ] **Step 5: Confirm `Helpers.actor_uuid/1` exists**

Check `lib/phoenix_kit_document_creator/web/helpers.ex`. The moduledoc references pulling the actor uuid. If the public function is named differently (e.g. only `actor_opts/1`), add:

```elixir
  @doc "Returns the acting user's uuid, or nil."
  def actor_uuid(socket) do
    socket.assigns[:phoenix_kit_current_scope] |> actor_uuid_from_scope()
  end
```

Match the existing extraction logic in that module rather than duplicating it — reuse the private helper the moduledoc describes.

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/phoenix_kit_document_creator/web/preset_form_live_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/phoenix_kit_document_creator/web/preset_form_live.ex \
        lib/phoenix_kit_document_creator/documents.ex \
        lib/phoenix_kit_document_creator/web/helpers.ex \
        test/phoenix_kit_document_creator/web/preset_form_live_test.exs
git commit -m "feat(presets): add PresetFormLive name/description/type form"
```

---

## Task 6: `PresetFormLive` — section editor

Adds an in-form editor for the `sections` array: add, remove, and drag-reorder template-backed sections. Sections live in socket state as a list of maps and are submitted as a serialized field. The drag hook is the existing `SortableGrid` (used in `CategoriesLive`).

**Files:**
- Modify: `lib/phoenix_kit_document_creator/web/preset_form_live.ex`
- Test: `test/phoenix_kit_document_creator/web/preset_form_live_test.exs`

- [ ] **Step 1: Write the failing test**

Append a new `describe` block before the final `end` of the test file:

```elixir
  describe "section editor" do
    setup :setup_category

    test "adds and saves a template section", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, tmpl} =
        PhoenixKitDocumentCreator.Schemas.Template.changeset(
          %PhoenixKitDocumentCreator.Schemas.Template{},
          %{name: "Cover", google_doc_id: "gd-cover", status: "published",
            category_uuid: cat.uuid}
        )
        |> PhoenixKitDocumentCreator.Repo.insert()

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/presets/new")

      view |> element("button", "Add section") |> render_click()

      view
      |> form("form",
        preset: %{name: "WithSection"},
        section: %{"0" => %{template_uuid: tmpl.uuid}}
      )
      |> render_submit()

      assert [preset] = Documents.list_presets(%{scope_id: cat.uuid})
      assert [%{"template_uuid" => uuid}] = preset.sections
      assert uuid == tmpl.uuid
    end
  end
```

NOTE: the exact form field names (`section[0][template_uuid]`) must match the markup written in Step 3 — keep them in sync.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/phoenix_kit_document_creator/web/preset_form_live_test.exs`
Expected: FAIL — no "Add section" button.

- [ ] **Step 3: Add section state and events**

In `preset_form_live.ex`:

(a) In `load/5`, add `sections` to the assigns, normalizing the stored JSONB array into editor maps:

```elixir
      sections: editor_sections(preset.sections),
```

(b) Add private helpers near the bottom of the module:

```elixir
  # Normalizes stored section maps (string keys) into editor rows.
  defp editor_sections(sections) when is_list(sections) do
    sections
    |> Enum.sort_by(&Map.get(&1, "position", 0))
    |> Enum.map(fn s ->
      %{
        "template_uuid" => Map.get(s, "template_uuid"),
        "variable_values" => Map.get(s, "variable_values", %{}),
        "image_params" => Map.get(s, "image_params", %{})
      }
    end)
  end

  defp editor_sections(_), do: []

  # Templates selectable for this preset's category.
  defp category_templates(category_uuid) do
    Documents.list_templates_from_db()
    |> Enum.filter(&(&1.category_uuid == category_uuid))
  end

  defp template_broken?(nil), do: true

  defp template_broken?(template) do
    template.status in ["trashed", "lost"]
  end
```

(c) Add `templates` to `load/5` assigns: `templates: category_templates(category.uuid)`.

(d) Add event handlers (place with the other `handle_event/3` clauses):

```elixir
  def handle_event("add_section", _params, socket) do
    section = %{"template_uuid" => nil, "variable_values" => %{}, "image_params" => %{}}
    {:noreply, assign(socket, sections: socket.assigns.sections ++ [section])}
  end

  def handle_event("remove_section", %{"index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, assign(socket, sections: List.delete_at(socket.assigns.sections, index))}
  end

  def handle_event("reorder_sections", %{"ordered_ids" => ids}, socket) do
    by_index = Enum.with_index(socket.assigns.sections)

    reordered =
      Enum.map(ids, fn id ->
        {section, _} = Enum.find(by_index, fn {_s, i} -> Integer.to_string(i) == id end)
        section
      end)

    {:noreply, assign(socket, sections: reordered)}
  end
```

(e) In `handle_event("save", ...)`, build the `sections` value from the submitted `section` param map merged with socket state. Replace `build_params/2` body's start:

```elixir
  defp build_params(params, socket) do
    type_uuid = blank_to_nil(params["scope_type"])
    sections = collect_sections(params["section"], socket.assigns.sections)

    params
    |> Map.drop(["section"])
    |> Map.put("sections", sections)
    |> Map.put("scope_id", socket.assigns.category.uuid)
    |> Map.put("scope_type", type_uuid)
    |> Map.put_new("created_by_uuid", Helpers.actor_uuid(socket) || socket.assigns.preset.created_by_uuid)
  end

  # Merges submitted per-section template choices with socket section state,
  # assigning position by current order.
  defp collect_sections(nil, _state), do: []

  defp collect_sections(section_params, _state) do
    section_params
    |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
    |> Enum.with_index()
    |> Enum.map(fn {{_index, attrs}, position} ->
      %{
        "template_uuid" => blank_to_nil(attrs["template_uuid"]),
        "position" => position,
        "variable_values" => %{},
        "image_params" => %{}
      }
    end)
  end
```

(f) In `render/1`, add the section editor block inside the `<.form>`, before the buttons:

```elixir
        <div class="form-control">
          <div class="flex items-center justify-between">
            <span class="label-text font-medium">{gettext("Sections")}</span>
            <button type="button" phx-click="add_section" class="btn btn-xs btn-ghost">
              <span class="hero-plus w-3 h-3" /> {gettext("Add section")}
            </button>
          </div>

          <ul
            id="preset-sections-sortable"
            class="flex flex-col gap-2 mt-2"
            phx-hook="SortableGrid"
            data-sortable="true"
            data-sortable-event="reorder_sections"
            data-sortable-items=".sortable-item"
            data-sortable-handle=".pk-drag-handle"
            data-sortable-hide-source="false"
          >
            <%= for {section, index} <- Enum.with_index(@sections) do %>
              <li class="sortable-item flex items-center gap-2 p-2 border border-base-200 rounded" data-id={index}>
                <span class="pk-drag-handle cursor-grab text-base-content/30">
                  <span class="hero-bars-3 w-4 h-4" />
                </span>
                <select name={"section[#{index}][template_uuid]"} class="select select-bordered select-sm flex-1">
                  <option value="">{gettext("— pick a template —")}</option>
                  <%= for tmpl <- @templates do %>
                    <option value={tmpl.uuid} selected={section["template_uuid"] == tmpl.uuid}>
                      {tmpl.name}
                    </option>
                  <% end %>
                </select>
                <span
                  :if={section["template_uuid"] && !Enum.any?(@templates, &(&1.uuid == section["template_uuid"]))}
                  class="text-warning text-xs"
                  title={gettext("Template missing or trashed")}
                >
                  <span class="hero-exclamation-triangle w-4 h-4" />
                </span>
                <button
                  type="button"
                  phx-click="remove_section"
                  phx-value-index={index}
                  class="btn btn-ghost btn-xs text-error"
                >
                  <span class="hero-x-mark w-4 h-4" />
                </button>
              </li>
            <% end %>
          </ul>
        </div>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/phoenix_kit_document_creator/web/preset_form_live_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/web/preset_form_live.ex \
        test/phoenix_kit_document_creator/web/preset_form_live_test.exs
git commit -m "feat(presets): add section editor with add/remove/reorder"
```

---

## Task 7: `PresetFormLive` — per-section variable & image defaults

Each section can carry default `variable_values` and `image_params`. Defaults are edited per template variable: text variables get a text input; image variables reuse `VariableConfigForm` / `ImagePicker` patterns already in the codebase.

**Files:**
- Modify: `lib/phoenix_kit_document_creator/web/preset_form_live.ex`
- Test: `test/phoenix_kit_document_creator/web/preset_form_live_test.exs`

- [ ] **Step 1: Write the failing test**

Append to the `"section editor"` describe block:

```elixir
    test "saves default variable values for a section", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, tmpl} =
        PhoenixKitDocumentCreator.Schemas.Template.changeset(
          %PhoenixKitDocumentCreator.Schemas.Template{},
          %{name: "Cover", google_doc_id: "gd-cover2", status: "published",
            category_uuid: cat.uuid,
            variables: [%{"name" => "client_name", "type" => "text"}]}
        )
        |> PhoenixKitDocumentCreator.Repo.insert()

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/presets/new")

      view |> element("button", "Add section") |> render_click()

      view
      |> form("form",
        preset: %{name: "WithVars"},
        section: %{
          "0" => %{
            template_uuid: tmpl.uuid,
            variable_values: %{"client_name" => "ACME Ltd"}
          }
        }
      )
      |> render_submit()

      assert [preset] = Documents.list_presets(%{scope_id: cat.uuid})
      assert [%{"variable_values" => %{"client_name" => "ACME Ltd"}}] = preset.sections
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/phoenix_kit_document_creator/web/preset_form_live_test.exs`
Expected: FAIL — `variable_values` is saved as `%{}`.

- [ ] **Step 3: Render variable inputs and collect them**

In `preset_form_live.ex`:

(a) Add a helper that resolves a section's template variables:

```elixir
  defp section_variables(section, templates) do
    case Enum.find(templates, &(&1.uuid == section["template_uuid"])) do
      nil -> []
      template -> template.variables || []
    end
  end
```

(b) In the section `<li>` markup (Task 6 Step 3f), after the `<select>` row, add a variable defaults block:

```elixir
                <div class="flex flex-col gap-1 w-full">
                  <%= for var <- section_variables(section, @templates) do %>
                    <% vname = var["name"] || var[:name] %>
                    <label class="text-xs flex flex-col gap-0.5">
                      <span class="text-base-content/60">{vname}</span>
                      <input
                        type="text"
                        name={"section[#{index}][variable_values][#{vname}]"}
                        value={Map.get(section["variable_values"] || %{}, vname, "")}
                        class="input input-bordered input-xs"
                      />
                    </label>
                  <% end %>
                </div>
```

Restructure the `<li>` so the drag handle + select + warning + remove sit on a top row and the variable block sits below (wrap the top row in a `<div class="flex items-center gap-2 w-full">`).

(c) Update `collect_sections/2` to read `variable_values` (and `image_params` when present) from the submitted attrs:

```elixir
  defp collect_sections(section_params, _state) do
    section_params
    |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
    |> Enum.with_index()
    |> Enum.map(fn {{_index, attrs}, position} ->
      %{
        "template_uuid" => blank_to_nil(attrs["template_uuid"]),
        "position" => position,
        "variable_values" => attrs["variable_values"] || %{},
        "image_params" => attrs["image_params"] || %{}
      }
    end)
  end
```

(d) So newly rendered variable inputs survive a re-render after `add_section`/`remove_section`, mirror submitted `variable_values` back into socket `sections` in a `handle_event("validate", ...)` extension — keep `validate` updating `sections` from `params["section"]`:

```elixir
  def handle_event("validate", %{"preset" => params} = all, socket) do
    sections =
      case all["section"] do
        nil -> socket.assigns.sections
        section_params -> collect_sections(section_params, socket.assigns.sections)
      end

    changeset =
      socket.assigns.preset
      |> TemplatePreset.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :preset), sections: sections)}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/phoenix_kit_document_creator/web/preset_form_live_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/web/preset_form_live.ex \
        test/phoenix_kit_document_creator/web/preset_form_live_test.exs
git commit -m "feat(presets): edit per-section variable defaults"
```

---

## Task 8: Presets panel on `CategoriesLive`

Adds the full-width Presets panel below the two columns: lists the selected category's presets grouped by type, with a New action, row menu (Edit / Delete), delete confirm, and the stale badge.

**Files:**
- Modify: `lib/phoenix_kit_document_creator/web/categories_live.ex`
- Test: `test/phoenix_kit_document_creator/web/categories_live_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/phoenix_kit_document_creator/web/categories_live_test.exs` (inside the test module, before its final `end`):

```elixir
  describe "presets panel" do
    test "lists presets of the selected category and deletes one", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Legal"})

      {:ok, preset} =
        Documents.save_preset(%{
          name: "Standard",
          scope_id: cat.uuid,
          created_by_uuid: Ecto.UUID.generate()
        })

      {:ok, view, _} = live(conn, "/en/admin/document-creator/categories")
      view |> element("button", "Legal") |> render_click()

      assert render(view) =~ "Standard"

      view
      |> element(~s{button[phx-value-uuid="#{preset.uuid}"][phx-click="delete_preset"]})
      |> render_click()

      assert Documents.list_presets(%{scope_id: cat.uuid}) == []
    end
  end
```

Ensure `alias PhoenixKitDocumentCreator.Documents` is present in the test module (add it next to the existing aliases if missing).

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/phoenix_kit_document_creator/web/categories_live_test.exs`
Expected: FAIL — no preset rows / no `delete_preset` event.

- [ ] **Step 3: Load presets in `CategoriesLive`**

In `categories_live.ex`:

(a) Add aliases: `alias PhoenixKitDocumentCreator.Documents`.

(b) Add `presets: []` to the `mount/3` assigns.

(c) Add a `reload_presets/1` helper and call it from `reload_types/1`'s end (so it refreshes whenever the selected category changes). Add near the other reload helpers:

```elixir
  defp reload_presets(socket) do
    case socket.assigns.selected do
      nil ->
        assign(socket, presets: [])

      category ->
        presets =
          %{scope_id: category.uuid}
          |> Documents.list_presets()
          |> Enum.map(fn preset ->
            %{preset: preset, stale: Documents.preset_stale_info(preset)}
          end)

        assign(socket, presets: presets)
    end
  end
```

In `reload_types/1`, pipe the result through `reload_presets/1`:

```elixir
  defp reload_types(socket) do
    socket =
      case socket.assigns.selected do
        nil ->
          assign(socket, types: [])

        category ->
          opts = if socket.assigns.types_trash, do: [status: "deleted"], else: []
          assign(socket, types: Taxonomy.list_types_for_category(category.uuid, opts))
      end

    reload_presets(socket)
  end
```

- [ ] **Step 4: Add the `delete_preset` event**

Add with the other `handle_event/3` clauses:

```elixir
  def handle_event("delete_preset", %{"uuid" => uuid}, socket) do
    case Documents.get_preset(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That preset no longer exists."))
         |> reload_presets()}

      preset ->
        case Documents.delete_preset(preset) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Preset deleted."))
             |> reload_presets()}

          {:error, reason} ->
            Logger.error("delete_preset failed: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, gettext("Could not delete preset."))}
        end
    end
  end
```

- [ ] **Step 5: Render the Presets panel**

In `render/1`, after the closing `</div>` of the `grid grid-cols-2` block and before the outer closing `</div>`:

```elixir
      <%= if @selected and not @categories_trash do %>
        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-4">
            <div class="flex items-center justify-between mb-3">
              <h2 class="card-title text-base">{gettext("Presets")}</h2>
              <a
                href={Routes.path("/admin/document-creator/categories/#{@selected.uuid}/presets/new")}
                class="btn btn-primary btn-xs"
              >
                <span class="hero-plus w-3 h-3" /> {gettext("New preset")}
              </a>
            </div>

            <%= if @presets == [] do %>
              <p class="text-sm text-base-content/50 py-4 text-center">
                {gettext("No presets for this category yet.")}
              </p>
            <% else %>
              <%= for {type_label, rows} <- group_presets_by_type(@presets, @types) do %>
                <h3 class="text-sm font-semibold text-base-content/70 mt-3 mb-1">{type_label}</h3>
                <ul class="flex flex-col gap-1">
                  <%= for %{preset: preset, stale: stale} <- rows do %>
                    <li class="flex items-center gap-2 px-2 py-1.5 rounded hover:bg-base-200">
                      <span class="flex-1 text-sm font-medium">{preset.name}</span>
                      <span
                        :if={stale.broken_count > 0}
                        class="badge badge-warning badge-sm gap-1"
                        title={gettext("Sections reference missing or trashed templates")}
                      >
                        <span class="hero-exclamation-triangle w-3 h-3" />
                        {ngettext("%{count} broken template", "%{count} broken templates", stale.broken_count, count: stale.broken_count)}
                      </span>
                      <span class="text-xs text-base-content/50">
                        {ngettext("%{count} section", "%{count} sections", length(preset.sections), count: length(preset.sections))}
                      </span>
                      <.preset_row_menu preset={preset} />
                    </li>
                  <% end %>
                </ul>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
```

- [ ] **Step 6: Add the `preset_row_menu` component and grouping helper**

Add a private component next to `type_row_menu/1`:

```elixir
  defp preset_row_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <button type="button" tabindex="0" class="btn btn-ghost btn-xs">
        <span class="hero-ellipsis-horizontal w-4 h-4" />
      </button>
      <ul tabindex="0" class="dropdown-content menu bg-base-100 rounded-box z-10 w-40 p-1 shadow-sm border border-base-200">
        <li>
          <a href={Routes.path("/admin/document-creator/presets/#{@preset.uuid}/edit")} class="text-xs">
            <span class="hero-pencil w-3 h-3" /> {gettext("Edit")}
          </a>
        </li>
        <li>
          <button
            type="button"
            phx-click="delete_preset"
            phx-value-uuid={@preset.uuid}
            data-confirm={gettext("Delete this preset permanently?")}
            class="text-xs text-error"
          >
            <span class="hero-trash w-3 h-3" /> {gettext("Delete")}
          </button>
        </li>
      </ul>
    </div>
    """
  end
```

Add a grouping helper near the other private helpers:

```elixir
  # Groups preset rows by their `scope_type` (a Type uuid). Untyped presets
  # come last under a localized "Untyped" heading.
  defp group_presets_by_type(presets, types) do
    type_name = Map.new(types, fn t -> {t.uuid, t.name} end)

    presets
    |> Enum.group_by(fn %{preset: p} -> p.scope_type end)
    |> Enum.map(fn {type_uuid, rows} ->
      label = if type_uuid, do: Map.get(type_name, type_uuid, gettext("Unknown type")), else: gettext("Untyped")
      sort_key = if type_uuid, do: {0, label}, else: {1, ""}
      {sort_key, label, rows}
    end)
    |> Enum.sort_by(fn {sort_key, _, _} -> sort_key end)
    |> Enum.map(fn {_, label, rows} -> {label, rows} end)
  end
```

- [ ] **Step 7: Run test to verify it passes**

Run: `mix test test/phoenix_kit_document_creator/web/categories_live_test.exs`
Expected: PASS.

- [ ] **Step 8: Run the full suite and quality checks**

Run: `mix test && mix format && mix quality`
Expected: all tests pass, no formatting diff, quality clean.

- [ ] **Step 9: Commit**

```bash
git add lib/phoenix_kit_document_creator/web/categories_live.ex \
        test/phoenix_kit_document_creator/web/categories_live_test.exs
git commit -m "feat(presets): add presets panel to CategoriesLive"
```

---

## Task 9: Gettext extraction and translations

**Files:**
- Modify: `priv/gettext/default.pot`
- Modify: `priv/gettext/en/LC_MESSAGES/default.po`
- Modify: `priv/gettext/et/LC_MESSAGES/default.po`
- Modify: `priv/gettext/ru/LC_MESSAGES/default.po`

- [ ] **Step 1: Extract and merge messages**

Run: `mix gettext.extract && mix gettext.merge priv/gettext`
Expected: new `msgid` entries for every new string appear in all three locale `default.po` files with empty `msgstr`.

- [ ] **Step 2: Fill in translations**

Edit each locale `.po` file and provide a non-empty `msgstr` for every new `msgid`. New strings introduced by this feature:

`Preset`, `New Preset`, `Edit Preset`, `Preset saved.`, `Could not save preset.`,
`Category`, `Name`, `Description`, `Document type`, `Untyped`, `Save`, `Cancel`,
`Sections`, `Add section`, `— pick a template —`, `Template missing or trashed`,
`Presets`, `New preset`, `No presets for this category yet.`,
`Sections reference missing or trashed templates`, `Edit`, `Delete`,
`Delete this preset permanently?`, `That preset no longer exists.`,
`Preset deleted.`, `Could not delete preset.`, `Unknown type`,
and the plural forms `%{count} broken template` / `%{count} section`.

- For `en`: `msgstr` equals the `msgid` (English source).
- For `ru` and `et`: provide proper translations. Match the tone of existing
  entries in each file. For plural `msgid_plural` entries, fill every
  `msgstr[N]` slot the locale's `Plural-Forms` header requires (Russian has 3).

- [ ] **Step 3: Verify no empty translations remain**

Run: `grep -n 'msgstr ""' priv/gettext/ru/LC_MESSAGES/default.po priv/gettext/et/LC_MESSAGES/default.po`
Expected: no output for the new msgids (header `msgstr ""` at the top of the file is normal — ignore line 1 area).

- [ ] **Step 4: Run the gettext test and full suite**

Run: `mix test test/gettext_test.exs && mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/gettext
git commit -m "i18n(presets): extract and translate preset management strings"
```

---

## Self-Review Notes

- **Spec coverage:** storage convention (Task 1), context CRUD + staleness (Tasks 2–3), routes (Task 4), `PresetFormLive` form + section editor + variable defaults (Tasks 5–7), Presets panel with grouping/stale badge/delete (Task 8), Gettext in en/et/ru (Task 9). Trash and migrations are explicitly out of scope per the spec.
- **Verify-before-coding hooks:** Task 5 Step 5 and Task 6 Step 1 note signatures (`Helpers.actor_uuid/1`, `Taxonomy.create_type/2`) that must be confirmed against the codebase before relying on them.
- **Type consistency:** `preset_stale_info/1` returns `%{broken_count, broken_template_uuids}` — consumed unchanged in Task 8. Section editor maps use string keys (`"template_uuid"`, `"position"`, `"variable_values"`, `"image_params"`) consistently across Tasks 6–8, matching the JSONB shape used by `apply_preset/1`.
