defmodule PhoenixKitDocumentCreator.Web.DocumentsLive do
  @moduledoc """
  Main landing page for the Document Creator.

  Two views:
  - **Google Docs view**: Template gallery row at top, documents grid below.
  - **Tabbed view**: Tab 1 = Templates, Tab 2 = Documents.

  Includes a create-document modal (blank or from template with variable form).
  """
  use Phoenix.LiveView

  import PhoenixKitDocumentCreator.Web.Components.CreateDocumentModal

  alias PhoenixKitDocumentCreator.Documents

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
       view_mode: "tabs",
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

  # ── View toggle ────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, view_mode: mode)}
  end

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
         |> redirect(to: "document-creator/documents/#{doc.uuid}/edit")}

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
         |> redirect(to: "document-creator/documents/#{doc.uuid}/edit")}

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
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-4">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Document Creator</h1>
        <div class="flex gap-2">
          <%!-- View toggle --%>
          <div class="join">
            <button
              class={"join-item btn btn-sm #{if @view_mode == "docs", do: "btn-active", else: ""}"}
              phx-click="switch_view"
              phx-value-mode="docs"
            >
              <span class="hero-squares-2x2 w-4 h-4" />
            </button>
            <button
              class={"join-item btn btn-sm #{if @view_mode == "tabs", do: "btn-active", else: ""}"}
              phx-click="switch_view"
              phx-value-mode="tabs"
            >
              <span class="hero-queue-list w-4 h-4" />
            </button>
          </div>
          <a
            href="document-creator/templates/new"
            class="btn btn-ghost btn-sm"
          >
            <span class="hero-plus w-4 h-4" /> New Template
          </a>
          <button class="btn btn-primary btn-sm" phx-click="open_modal">
            <span class="hero-document-plus w-4 h-4" /> New Document
          </button>
        </div>
      </div>

      <%!-- View content --%>
      <%= if @view_mode == "docs" do %>
        {render_docs_view(assigns)}
      <% else %>
        {render_tabs_view(assigns)}
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
    """
  end

  # ── Google Docs view ───────────────────────────────────────────────

  defp render_docs_view(assigns) do
    published = Enum.filter(assigns.templates, &(&1.status == "published"))
    assigns = Map.put(assigns, :published_templates, published)

    ~H"""
    <%!-- Template gallery row --%>
    <div :if={@published_templates != []} class="space-y-2">
      <h2 class="text-sm font-medium text-base-content/60 uppercase tracking-wide">
        Start from a template
      </h2>
      <div class="flex gap-3 overflow-x-auto pb-2">
        <button
          :for={tpl <- @published_templates}
          class="flex-shrink-0 w-40 p-3 rounded-lg border border-base-content/15 hover:border-primary hover:bg-primary/5 transition-all text-left"
          phx-click="open_modal_with_template"
          phx-value-uuid={tpl.uuid}
        >
          <div class="w-full h-20 bg-base-200 rounded mb-2 flex items-center justify-center">
            <span class="hero-document-text w-8 h-8 text-base-content/20" />
          </div>
          <p class="text-sm font-medium truncate">{tpl.name}</p>
          <p :if={tpl.description} class="text-xs text-base-content/50 truncate">{tpl.description}</p>
        </button>
      </div>
    </div>

    <%!-- Documents grid --%>
    <div class="space-y-2">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-medium text-base-content/60 uppercase tracking-wide">
          Recent Documents
        </h2>
      </div>

      <div :if={@documents == []} class="card bg-base-100 shadow-sm">
        <div class="card-body items-center text-center py-12">
          <span class="hero-document-plus w-12 h-12 text-base-content/20" />
          <p class="text-sm text-base-content/50 mt-2">No documents yet</p>
          <button class="btn btn-primary btn-sm mt-3" phx-click="open_modal">
            Create Your First Document
          </button>
        </div>
      </div>

      <div :if={@documents != []} class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
        <div :for={doc <- @documents} class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow">
          <div class="card-body p-4">
            <div class="flex items-start justify-between">
              <div class="flex-1 min-w-0">
                <h3 class="font-medium truncate">{doc.name}</h3>
                <p class="text-xs text-base-content/50 mt-1">
                  {Calendar.strftime(doc.updated_at, "%b %d, %Y")}
                </p>
              </div>
              <span class={"badge badge-sm #{status_badge_class(doc.status)}"}>{doc.status}</span>
            </div>
            <div class="flex gap-2 mt-3">
              <a
                href={"document-creator/documents/#{doc.uuid}/edit"}
                class="btn btn-ghost btn-xs flex-1"
              >
                <span class="hero-pencil-square w-3 h-3" /> Edit
              </a>
              {render_delete_button(Map.merge(assigns, %{item_uuid: doc.uuid, item_type: "document"}))}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Tabbed view ────────────────────────────────────────────────────

  defp render_tabs_view(assigns) do
    ~H"""
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

    <%= if @active_tab == "templates" do %>
      {render_templates_tab(assigns)}
    <% else %>
      {render_documents_tab(assigns)}
    <% end %>
    """
  end

  defp render_templates_tab(assigns) do
    ~H"""
    <div :if={@templates == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-12">
        <span class="hero-document-text w-12 h-12 text-base-content/20" />
        <p class="text-sm text-base-content/50 mt-2">No templates yet</p>
        <a
          href="document-creator/templates/new"
          class="btn btn-primary btn-sm mt-3"
        >
          Create First Template
        </a>
      </div>
    </div>

    <div :if={@templates != []} class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Name</th>
            <th>Status</th>
            <th>Variables</th>
            <th>Updated</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={tpl <- @templates} class="hover">
            <td>
              <div>
                <p class="font-medium">{tpl.name}</p>
                <p :if={tpl.description} class="text-xs text-base-content/50 truncate max-w-xs">
                  {tpl.description}
                </p>
              </div>
            </td>
            <td>
              <span class={"badge badge-sm #{status_badge_class(tpl.status)}"}>{tpl.status}</span>
            </td>
            <td>
              <div class="flex flex-wrap gap-1">
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
            </td>
            <td class="text-xs text-base-content/50">
              {Calendar.strftime(tpl.updated_at, "%b %d, %Y")}
            </td>
            <td>
              <div class="flex gap-1 justify-end">
                <button
                  :if={tpl.status == "published"}
                  class="btn btn-ghost btn-xs"
                  phx-click="open_modal_with_template"
                  phx-value-uuid={tpl.uuid}
                >
                  <span class="hero-document-plus w-3 h-3" /> Use
                </button>
                <a
                  href={"document-creator/templates/#{tpl.uuid}/edit"}
                  class="btn btn-ghost btn-xs"
                >
                  <span class="hero-pencil-square w-3 h-3" /> Edit
                </a>
                {render_delete_button(Map.merge(assigns, %{item_uuid: tpl.uuid, item_type: "template"}))}
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp render_documents_tab(assigns) do
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

    <div :if={@documents != []} class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Name</th>
            <th>Status</th>
            <th>Updated</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={doc <- @documents} class="hover">
            <td class="font-medium">{doc.name}</td>
            <td>
              <span class={"badge badge-sm #{status_badge_class(doc.status)}"}>{doc.status}</span>
            </td>
            <td class="text-xs text-base-content/50">
              {Calendar.strftime(doc.updated_at, "%b %d, %Y")}
            </td>
            <td>
              <div class="flex gap-1 justify-end">
                <a
                  href={"document-creator/documents/#{doc.uuid}/edit"}
                  class="btn btn-ghost btn-xs"
                >
                  <span class="hero-pencil-square w-3 h-3" /> Edit
                </a>
                {render_delete_button(Map.merge(assigns, %{item_uuid: doc.uuid, item_type: "document"}))}
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ── Shared components ──────────────────────────────────────────────

  defp render_delete_button(assigns) do
    ~H"""
    <%= if @confirm_delete == @item_uuid do %>
      <button
        class="btn btn-error btn-xs"
        phx-click="delete"
        phx-value-uuid={@item_uuid}
        phx-value-type={@item_type}
      >
        Confirm
      </button>
      <button class="btn btn-ghost btn-xs" phx-click="cancel_delete">Cancel</button>
    <% else %>
      <button
        class="btn btn-ghost btn-xs text-error"
        phx-click="confirm_delete"
        phx-value-uuid={@item_uuid}
        phx-value-type={@item_type}
      >
        <span class="hero-trash w-3 h-3" />
      </button>
    <% end %>
    """
  end

  defp status_badge_class("published"), do: "badge-success"
  defp status_badge_class("draft"), do: "badge-warning"
  defp status_badge_class("archived"), do: "badge-ghost"
  defp status_badge_class("final"), do: "badge-info"
  defp status_badge_class(_), do: ""

  defp assign_modal_templates(assigns) do
    if Map.has_key?(assigns, :modal_templates) do
      assigns
    else
      Map.put(assigns, :modal_templates, [])
    end
  end
end
