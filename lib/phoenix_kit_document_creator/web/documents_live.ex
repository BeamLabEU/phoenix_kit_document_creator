defmodule PhoenixKitDocumentCreator.Web.DocumentsLive do
  @moduledoc """
  Main landing page for the Document Creator.

  Shows templates and documents as card grids with scaled page previews.
  Includes a create-document modal (blank or from template with variable form).
  """
  use Phoenix.LiveView

  import PhoenixKitDocumentCreator.Web.Components.CreateDocumentModal

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Paths

  # Preview iframe is rendered at full page width (794px for A4) then CSS-scaled
  # down by 0.23 to fit ~183px wide card preview area.
  # Container: 183×258px, iframe: 794×1123px, scale(0.23)

  @impl true
  def mount(_params, _session, socket) do
    {templates, documents} =
      if connected?(socket) do
        {Documents.list_templates(), Documents.list_documents()}
      else
        {[], []}
      end

    {:ok,
     assign(socket,
       page_title: "Document Creator",
       active_tab: "templates",
       templates: templates,
       documents: documents,
       # Modal state
       modal_open: false,
       modal_step: "choose",
       modal_selected_template: nil,
       modal_creating: false,
       # Delete confirmation
       confirm_delete: nil,
       confirm_delete_type: nil
     )}
  end

  # ── Tab switch ──────────────────────────────────────────────────

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  # ── Modal events ───────────────────────────────────────────────────

  def handle_event("open_modal", _params, socket) do
    published = Documents.published_templates()

    {:noreply,
     assign(socket,
       modal_open: true,
       modal_step: "choose",
       modal_selected_template: nil,
       modal_creating: false,
       templates: Documents.list_templates(),
       modal_templates: published
     )}
  end

  def handle_event("open_modal_with_template", %{"uuid" => uuid}, socket) do
    case Documents.get_template(uuid) do
      nil ->
        {:noreply, socket}

      template ->
        {:noreply,
         assign(socket,
           modal_open: true,
           modal_step: "variables",
           modal_selected_template: template,
           modal_creating: false
         )}
    end
  end

  def handle_event("modal_close", _params, socket) do
    {:noreply, assign(socket, modal_open: false)}
  end

  def handle_event("modal_back", _params, socket) do
    {:noreply, assign(socket, modal_step: "choose", modal_selected_template: nil)}
  end

  def handle_event("modal_create_blank", _params, socket) do
    case Documents.create_document(%{name: "Untitled Document"}) do
      {:ok, doc} ->
        {:noreply,
         socket
         |> assign(modal_open: false)
         |> redirect(to: Paths.document_edit(doc.uuid))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("modal_select_template", %{"uuid" => uuid}, socket) do
    case Documents.get_template(uuid) do
      nil ->
        {:noreply, socket}

      template ->
        {:noreply, assign(socket, modal_step: "variables", modal_selected_template: template)}
    end
  end

  def handle_event("modal_create_from_template", params, socket) do
    template_uuid = Map.get(params, "template_uuid")
    doc_name = Map.get(params, "doc_name", "")
    variable_values = Map.get(params, "var", %{})

    case Documents.create_document_from_template(template_uuid, variable_values, name: doc_name) do
      {:ok, doc} ->
        {:noreply,
         socket
         |> assign(modal_open: false)
         |> redirect(to: Paths.document_edit(doc.uuid))}

      {:error, _reason} ->
        {:noreply, assign(socket, modal_creating: false)}
    end
  end

  # ── Delete events ──────────────────────────────────────────────────

  def handle_event("confirm_delete", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, confirm_delete: uuid, confirm_delete_type: type)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: nil, confirm_delete_type: nil)}
  end

  def handle_event("delete", %{"uuid" => uuid, "type" => type}, socket) do
    result =
      case type do
        "template" ->
          with %{} = t <- Documents.get_template(uuid), do: Documents.delete_template(t)

        "document" ->
          with %{} = d <- Documents.get_document(uuid), do: Documents.delete_document(d)

        _ ->
          {:error, :unknown_type}
      end

    case result do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           templates: Documents.list_templates(),
           documents: Documents.list_documents(),
           confirm_delete: nil,
           confirm_delete_type: nil
         )}

      _ ->
        {:noreply, assign(socket, confirm_delete: nil, confirm_delete_type: nil)}
    end
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign_modal_templates(assigns)

    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Document Creator</h1>
        <div class="flex gap-2">
          <a href={Paths.template_new()} class="btn btn-ghost btn-sm">
            <span class="hero-plus w-4 h-4" /> New Template
          </a>
          <button class="btn btn-primary btn-sm" phx-click="open_modal">
            <span class="hero-document-plus w-4 h-4" /> New Document
          </button>
        </div>
      </div>

      <%!-- Tabs --%>
      <div role="tablist" class="tabs tabs-bordered">
        <button
          role="tab"
          class={"tab #{if @active_tab == "templates", do: "tab-active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="templates"
        >
          Templates
          <span class="badge badge-sm ml-1">{length(@templates)}</span>
        </button>
        <button
          role="tab"
          class={"tab #{if @active_tab == "documents", do: "tab-active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="documents"
        >
          Documents
          <span class="badge badge-sm ml-1">{length(@documents)}</span>
        </button>
      </div>

      <%!-- Tab content --%>
      <%= if @active_tab == "templates" do %>
        {render_templates_grid(assigns)}
      <% else %>
        {render_documents_grid(assigns)}
      <% end %>
    </div>

    <%!-- Create document modal --%>
    <.modal
      open={@modal_open}
      templates={@modal_templates}
      step={@modal_step}
      selected_template={@modal_selected_template}
      creating={@modal_creating}
    />

    <style>
      .page-preview-container {
        width: 183px;
        height: 258px;
        overflow: hidden;
        position: relative;
        border-radius: 4px;
        background: #fff;
        border: 1px solid oklch(var(--color-base-content) / 0.2);
        box-shadow: 0 2px 8px rgba(0,0,0,0.15);
      }
      .page-preview-empty {
        width: 183px;
        height: 258px;
        border-radius: 4px;
        background: oklch(var(--color-base-200));
        border: 1px solid oklch(var(--color-base-300));
        display: flex;
        align-items: center;
        justify-content: center;
      }
    </style>
    """
  end

  # ── Templates grid ──────────────────────────────────────────────

  defp render_templates_grid(assigns) do
    ~H"""
    <div :if={@templates == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-12">
        <span class="hero-document-text w-12 h-12 text-base-content/20" />
        <p class="text-sm text-base-content/50 mt-2">No templates yet</p>
        <a href={Paths.template_new()} class="btn btn-primary btn-sm mt-3">
          Create First Template
        </a>
      </div>
    </div>

    <div :if={@templates != []} class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-4">
      <div
        :for={tpl <- @templates}
        class="group flex flex-col"
        style="border: 1.5px solid currentColor; border-radius: 8px; overflow: hidden; box-shadow: 0 4px 16px var(--color-neutral); background: oklch(var(--color-base-100)); padding-bottom: 12px;"
      >
        <%!-- Preview --%>
        <a href={Paths.template_edit(tpl.uuid)} style="display:flex;justify-content:center;padding:16px 16px 24px 16px;background:oklch(var(--color-base-200));">
          {render_page_preview(Map.merge(assigns, %{item: tpl}))}
        </a>

        <%!-- Info --%>
        <div class="p-3 flex-1 flex flex-col">
          <p class="font-medium text-sm truncate">{tpl.name}</p>
          <p :if={tpl.description} class="text-xs text-base-content/50 truncate mt-0.5">
            {tpl.description}
          </p>
          <div :if={(tpl.variables || []) != []} class="flex flex-wrap gap-1 mt-1.5">
            <span
              :for={var <- Enum.take(tpl.variables || [], 3)}
              class="badge badge-xs badge-ghost"
            >
              {var["name"] || var[:name]}
            </span>
            <span :if={length(tpl.variables || []) > 3} class="text-xs text-base-content/40">
              +{length(tpl.variables) - 3}
            </span>
          </div>
          <p class="text-xs text-base-content/40 mt-auto pt-2">
            {Calendar.strftime(tpl.updated_at, "%b %d, %Y")}
          </p>
        </div>

        <%!-- Actions --%>
        <div class="flex gap-1 px-2 pb-2 pt-1">
          <button
            class="flex-1 btn btn-ghost btn-xs py-2"
            phx-click="open_modal_with_template"
            phx-value-uuid={tpl.uuid}
          >
            <span class="hero-document-plus w-3 h-3" /> Use
          </button>
          <a
            href={Paths.template_edit(tpl.uuid)}
            class="flex-1 btn btn-ghost btn-xs py-2"
          >
            <span class="hero-pencil-square w-3 h-3" /> Edit
          </a>
          {render_delete_button(Map.merge(assigns, %{item_uuid: tpl.uuid, item_type: "template"}))}
        </div>
      </div>
    </div>
    """
  end

  # ── Documents grid ──────────────────────────────────────────────

  defp render_documents_grid(assigns) do
    ~H"""
    <div :if={@documents == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-12">
        <span class="hero-document-plus w-12 h-12 text-base-content/20" />
        <p class="text-sm text-base-content/50 mt-2">No documents yet</p>
        <button class="btn btn-primary btn-sm mt-3" phx-click="open_modal">
          Create First Document
        </button>
      </div>
    </div>

    <div :if={@documents != []} class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-4">
      <div
        :for={doc <- @documents}
        class="group flex flex-col"
        style="border: 1.5px solid currentColor; border-radius: 8px; overflow: hidden; box-shadow: 0 4px 16px var(--color-neutral); background: oklch(var(--color-base-100)); padding-bottom: 12px;"
      >
        <%!-- Preview --%>
        <a href={Paths.document_edit(doc.uuid)} style="display:flex;justify-content:center;padding:16px 16px 24px 16px;background:oklch(var(--color-base-200));">
          {render_page_preview(Map.merge(assigns, %{item: doc}))}
        </a>

        <%!-- Info --%>
        <div class="p-3 flex-1 flex flex-col">
          <p class="font-medium text-sm truncate">{doc.name}</p>
          <p class="text-xs text-base-content/40 mt-auto pt-2">
            {Calendar.strftime(doc.updated_at, "%b %d, %Y")}
          </p>
        </div>

        <%!-- Actions --%>
        <div class="flex gap-1 px-2 pb-2 pt-1">
          <a
            href={Paths.document_edit(doc.uuid)}
            class="flex-1 btn btn-ghost btn-xs py-2"
          >
            <span class="hero-pencil-square w-3 h-3" /> Edit
          </a>
          {render_delete_button(Map.merge(assigns, %{item_uuid: doc.uuid, item_type: "document"}))}
        </div>
      </div>
    </div>
    """
  end

  # ── Page preview ────────────────────────────────────────────────

  defp render_page_preview(assigns) do
    thumbnail = assigns.item.thumbnail
    has_thumbnail = is_binary(thumbnail) and thumbnail != ""
    assigns = Map.merge(assigns, %{has_thumbnail: has_thumbnail, thumbnail: thumbnail})

    ~H"""
    <%= if @has_thumbnail do %>
      <div class="page-preview-container mx-auto">
        <iframe src={@thumbnail} sandbox="" scrolling="no" style="width:794px;height:1123px;border:none;pointer-events:none;transform:scale(0.23);transform-origin:top left;" />
      </div>
    <% else %>
      <div class="page-preview-empty mx-auto">
        <span class="hero-document-text w-10 h-10 text-base-content/15" />
      </div>
    <% end %>
    """
  end

  # ── Shared components ──────────────────────────────────────────────

  defp render_delete_button(assigns) do
    ~H"""
    <%= if @confirm_delete == @item_uuid do %>
      <button
        class="flex-1 btn btn-error btn-xs py-2"
        phx-click="delete"
        phx-value-uuid={@item_uuid}
        phx-value-type={@item_type}
      >
        Confirm
      </button>
      <button class="flex-1 btn btn-ghost btn-xs py-2" phx-click="cancel_delete">Cancel</button>
    <% else %>
      <button
        class="flex-1 btn btn-ghost btn-xs text-error py-2"
        phx-click="confirm_delete"
        phx-value-uuid={@item_uuid}
        phx-value-type={@item_type}
      >
        <span class="hero-trash w-3 h-3" />
      </button>
    <% end %>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp assign_modal_templates(assigns) do
    if Map.has_key?(assigns, :modal_templates) do
      assigns
    else
      Map.put(assigns, :modal_templates, [])
    end
  end
end
