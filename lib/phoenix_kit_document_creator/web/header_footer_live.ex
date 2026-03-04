defmodule PhoenixKitDocumentCreator.Web.HeaderFooterLive do
  @moduledoc """
  Header/footer designer with GrapesJS mini editors.

  Two modes:
  - **List view** (default): Shows saved designs with create/edit/delete.
  - **Editor view**: GrapesJS mini editors with absolute positioning for
    visual header and footer layout design.
  """
  use Phoenix.LiveView

  import PhoenixKitDocumentCreator.Web.Components.EditorScripts

  alias PhoenixKitDocumentCreator.Documents

  @impl true
  def mount(_params, _session, socket) do
    items = if connected?(socket), do: Documents.list_headers_footers(), else: []

    {:ok,
     assign(socket,
       page_title: "Headers & Footers",
       items: items,
       editing: nil,
       saving: false,
       error: nil,
       confirm_delete: nil
     )}
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("new", _params, socket) do
    case Documents.create_header_footer(%{name: "Untitled Header/Footer"}) do
      {:ok, hf} ->
        {:noreply,
         socket
         |> assign(editing: hf, error: nil)
         |> push_event("init-hf-editors", %{
           header_native: nil,
           footer_native: nil
         })}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: "Failed to create header/footer")}
    end
  end

  def handle_event("edit", %{"uuid" => uuid}, socket) do
    case Documents.get_header_footer(uuid) do
      nil ->
        {:noreply, assign(socket, error: "Not found")}

      hf ->
        {:noreply,
         socket
         |> assign(editing: hf, error: nil)
         |> push_event("init-hf-editors", %{
           header_native: hf.header_native,
           footer_native: hf.footer_native
         })}
    end
  end

  def handle_event("back_to_list", _params, socket) do
    items = Documents.list_headers_footers()

    {:noreply,
     socket
     |> assign(editing: nil, items: items, error: nil)
     |> push_event("destroy-hf-editors", %{})}
  end

  def handle_event("request_save", _params, socket) do
    {:noreply,
     socket
     |> assign(saving: true)
     |> push_event("request-hf-save-data", %{})}
  end

  def handle_event("save_header_footer", params, socket) do
    hf = socket.assigns.editing

    decode_native = fn key ->
      case Jason.decode(Map.get(params, key, "")) do
        {:ok, decoded} -> decoded
        _ -> nil
      end
    end

    attrs = %{
      name: Map.get(params, "name", hf.name),
      header_html: Map.get(params, "header_html", ""),
      header_css: Map.get(params, "header_css", ""),
      header_native: decode_native.("header_native"),
      footer_html: Map.get(params, "footer_html", ""),
      footer_css: Map.get(params, "footer_css", ""),
      footer_native: decode_native.("footer_native"),
      header_height: Map.get(params, "header_height", hf.header_height),
      footer_height: Map.get(params, "footer_height", hf.footer_height)
    }

    case Documents.update_header_footer(hf, attrs) do
      {:ok, updated} ->
        {:noreply, assign(socket, editing: updated, saving: false, error: nil)}

      {:error, _changeset} ->
        {:noreply, assign(socket, saving: false, error: "Save failed")}
    end
  end

  def handle_event("confirm_delete", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, confirm_delete: uuid)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: nil)}
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Documents.get_header_footer(uuid) do
      nil ->
        {:noreply, assign(socket, confirm_delete: nil)}

      hf ->
        case Documents.delete_header_footer(hf) do
          {:ok, _} ->
            items = Documents.list_headers_footers()
            {:noreply, assign(socket, items: items, confirm_delete: nil)}

          {:error, _} ->
            {:noreply, assign(socket, error: "Delete failed", confirm_delete: nil)}
        end
    end
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.editor_scripts />
    <div id="hf-hook-container" phx-hook="GrapesJSHeaderFooter" class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <%= if @editing do %>
        {render_editor(assigns)}
      <% else %>
        {render_list(assigns)}
      <% end %>
    </div>

    <%!-- Mini GrapesJS editor styles --%>
    <style>
      .hf-mini-editor .gjs-editor,
      .hf-mini-editor .gjs-cv-canvas {
        background: #fff !important;
      }
      .hf-mini-editor .gjs-cv-canvas { width: 100% !important; }
      .hf-mini-editor .gjs-pn-panels,
      .hf-mini-editor .gjs-com-badge,
      .hf-mini-editor .gjs-toolbar {
        display: none !important;
      }
      .hf-blocks-panel {
        background: #f8f9fa !important;
      }
      .hf-blocks-panel .gjs-blocks-cs {
        display: flex; flex-direction: column; gap: 3px; padding: 6px;
      }
      .hf-blocks-panel .gjs-block {
        width: 100% !important; padding: 6px 8px !important;
        border: 1px solid #e0e0e0 !important; border-radius: 4px !important;
        background: #fff !important; cursor: grab; text-align: center;
        font-size: 10px !important; min-height: 0 !important;
      }
      .hf-blocks-panel .gjs-block:hover {
        border-color: oklch(var(--p)) !important;
        background: oklch(var(--p) / 0.05) !important;
      }
      .hf-blocks-panel .gjs-block svg { fill: #555; }
      .hf-blocks-panel .gjs-block-label {
        color: #1a1a1a !important; font-size: 10px !important;
      }
    </style>
    """
  end

  defp render_list(assigns) do
    ~H"""
    <%!-- Header bar --%>
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-3">
        <a
          href="document-creator"
          class="btn btn-ghost btn-sm btn-square"
        >
          <span class="hero-arrow-left w-5 h-5" />
        </a>
        <h1 class="text-xl font-bold">Headers & Footers</h1>
      </div>
      <button class="btn btn-primary btn-sm" phx-click="new">
        <span class="hero-plus w-4 h-4" /> New Design
      </button>
    </div>

    <div :if={@error} class="alert alert-error">
      <span class="hero-x-circle w-5 h-5" />
      <span>{@error}</span>
    </div>

    <%!-- Empty state --%>
    <div :if={@items == []} class="card bg-base-100 shadow-xl">
      <div class="card-body items-center text-center py-12">
        <span class="hero-bars-3 w-12 h-12 text-base-content/20" />
        <h3 class="text-lg font-medium mt-2">No header/footer designs yet</h3>
        <p class="text-sm text-base-content/60">
          Create reusable header and footer designs that can be assigned to templates.
        </p>
        <button class="btn btn-primary btn-sm mt-4" phx-click="new">
          <span class="hero-plus w-4 h-4" /> Create First Design
        </button>
      </div>
    </div>

    <%!-- List --%>
    <div :if={@items != []} class="space-y-3">
      <div :for={item <- @items} class="card bg-base-100 shadow-sm">
        <div class="card-body p-4 flex-row items-center justify-between">
          <div>
            <h3 class="font-medium">{item.name}</h3>
            <p class="text-xs text-base-content/50">
              Header: {item.header_height} | Footer: {item.footer_height}
              <span class="mx-1">·</span>
              Updated {Calendar.strftime(item.updated_at, "%b %d, %Y")}
            </p>
          </div>
          <div class="flex gap-2">
            <button
              class="btn btn-ghost btn-sm"
              phx-click="edit"
              phx-value-uuid={item.uuid}
            >
              <span class="hero-pencil-square w-4 h-4" /> Edit
            </button>
            <%= if @confirm_delete == item.uuid do %>
              <button
                class="btn btn-error btn-sm"
                phx-click="delete"
                phx-value-uuid={item.uuid}
              >
                Confirm
              </button>
              <button class="btn btn-ghost btn-sm" phx-click="cancel_delete">
                Cancel
              </button>
            <% else %>
              <button
                class="btn btn-ghost btn-sm text-error"
                phx-click="confirm_delete"
                phx-value-uuid={item.uuid}
              >
                <span class="hero-trash w-4 h-4" />
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_editor(assigns) do
    ~H"""
    <%!-- Header bar --%>
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-3">
        <button class="btn btn-ghost btn-sm btn-square" phx-click="back_to_list">
          <span class="hero-arrow-left w-5 h-5" />
        </button>
        <div>
          <h1 class="text-xl font-bold">Edit Header / Footer</h1>
          <p class="text-sm text-base-content/60">{@editing.name}</p>
        </div>
      </div>
      <button class="btn btn-primary btn-sm" phx-click="request_save" disabled={@saving}>
        <span :if={@saving} class="loading loading-spinner loading-xs" />
        <span :if={not @saving} class="hero-check w-4 h-4" />
        {if @saving, do: "Saving...", else: "Save"}
      </button>
    </div>

    <div :if={@error} class="alert alert-error">
      <span class="hero-x-circle w-5 h-5" />
      <span>{@error}</span>
    </div>

    <%!-- Settings row --%>
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body p-4">
        <div class="flex gap-4 items-end">
          <div class="form-control flex-1">
            <label class="label py-1"><span class="label-text text-xs">Name</span></label>
            <input
              type="text"
              id="hf-name"
              class="input input-bordered input-sm w-full"
              value={@editing.name}
            />
          </div>
          <div class="form-control w-28">
            <label class="label py-1"><span class="label-text text-xs">Header Height</span></label>
            <input
              type="text"
              id="hf-header-height"
              class="input input-bordered input-sm"
              value={@editing.header_height}
            />
          </div>
          <div class="form-control w-28">
            <label class="label py-1"><span class="label-text text-xs">Footer Height</span></label>
            <input
              type="text"
              id="hf-footer-height"
              class="input input-bordered input-sm"
              value={@editing.footer_height}
            />
          </div>
        </div>
      </div>
    </div>

    <%!-- Header editor --%>
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body p-4 space-y-2">
        <h3 class="font-semibold text-sm">Header Design</h3>
        <div
          id="hf-header-wrapper"
          phx-update="ignore"
          style="display:flex;border:1px solid oklch(var(--bc) / 0.2);border-radius:0.5rem;overflow:hidden;"
        >
          <div id="hf-header-editor" class="hf-mini-editor" style="flex:1;height:200px;"></div>
          <div
            id="hf-header-editor-blocks"
            class="hf-blocks-panel"
            style="width:120px;border-left:1px solid oklch(var(--bc) / 0.15);overflow-y:auto;"
          >
          </div>
        </div>
      </div>
    </div>

    <%!-- Footer editor --%>
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body p-4 space-y-2">
        <h3 class="font-semibold text-sm">Footer Design</h3>
        <div
          id="hf-footer-wrapper"
          phx-update="ignore"
          style="display:flex;border:1px solid oklch(var(--bc) / 0.2);border-radius:0.5rem;overflow:hidden;"
        >
          <div id="hf-footer-editor" class="hf-mini-editor" style="flex:1;height:200px;"></div>
          <div
            id="hf-footer-editor-blocks"
            class="hf-blocks-panel"
            style="width:120px;border-left:1px solid oklch(var(--bc) / 0.15);overflow-y:auto;"
          >
          </div>
        </div>
      </div>
    </div>

    <p class="text-xs text-base-content/50">
      Drag elements from the blocks panel. Use absolute positioning to place elements freely.
      The "Page #" block inserts page number placeholders for PDF output.
    </p>

    """
  end
end
