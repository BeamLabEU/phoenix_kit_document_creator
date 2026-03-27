defmodule PhoenixKitDocumentCreator.Web.HeaderFooterEditorLive do
  @moduledoc """
  Shared editor page for header and footer designs.

  Uses `live_action` to determine context:
  - `:header_new` / `:footer_new` — opens editor with an unsaved in-memory record
  - `:header_edit` / `:footer_edit` — loads existing record by UUID for editing

  The first save of a new record persists it and redirects to the edit URL.

  Shows a full page preview at paper dimensions where only the header or
  footer region is editable via GrapesJS. The rest of the page is a greyed-out
  non-interactive placeholder for visual context.
  """
  use Phoenix.LiveView

  import PhoenixKitDocumentCreator.Web.Components.EditorScripts

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Paths
  alias PhoenixKitDocumentCreator.Schemas.HeaderFooter

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       record: nil,
       type: nil,
       paper_size: "a4",
       saving: false,
       error: nil,
       saved_flash: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :header_new, _params), do: new_record(socket, "header")
  defp apply_action(socket, :footer_new, _params), do: new_record(socket, "footer")
  defp apply_action(socket, :header_edit, params), do: load_record(socket, "header", params)
  defp apply_action(socket, :footer_edit, params), do: load_record(socket, "footer", params)

  defp new_record(socket, type) do
    record = %HeaderFooter{
      type: type,
      name: "Untitled #{String.capitalize(type)}",
      height: "25mm",
      data: %{}
    }

    socket
    |> assign(
      page_title: "New #{String.capitalize(type)}",
      record: record,
      type: type,
      paper_size: "a4"
    )
    |> push_event("init-hf-editor", %{
      native: nil,
      type: type,
      height: "25mm",
      paper_size: "a4"
    })
  end

  defp load_record(socket, type, %{"uuid" => uuid}) do
    case Documents.get_header_footer(uuid) do
      nil ->
        socket
        |> put_flash(:error, "#{String.capitalize(type)} not found")
        |> redirect(to: hf_list_path(type))

      record ->
        paper_size = get_in(record.data || %{}, ["paper_size"]) || "a4"

        socket
        |> assign(
          page_title: "Edit: #{record.name}",
          record: record,
          type: type,
          paper_size: paper_size
        )
        |> push_event("init-hf-editor", %{
          native: record.native,
          type: type,
          height: record.height,
          paper_size: paper_size
        })
    end
  end

  defp hf_list_path("header"), do: Paths.headers()
  defp hf_list_path("footer"), do: Paths.footers()
  defp hf_list_path(_), do: Paths.index()

  defp hf_edit_path("header", uuid), do: Paths.header_edit(uuid)
  defp hf_edit_path("footer", uuid), do: Paths.footer_edit(uuid)

  # ── Save ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("request_save", _params, socket) do
    {:noreply, push_event(socket, "request-hf-save-data", %{})}
  end

  def handle_event("save_record", params, socket) do
    record = socket.assigns.record

    native =
      case Jason.decode(Map.get(params, "native", "")) do
        {:ok, decoded} -> decoded
        _ -> nil
      end

    existing_data = record.data || %{}

    attrs = %{
      name: Map.get(params, "name", record.name),
      html: Map.get(params, "html", ""),
      css: Map.get(params, "css", ""),
      native: native,
      height: Map.get(params, "height", record.height),
      data: Map.merge(existing_data, %{"paper_size" => Map.get(params, "paper_size", "a4")})
    }

    is_new = socket.assigns.live_action in [:header_new, :footer_new]

    socket = assign(socket, saving: true)

    result =
      if is_new do
        create_fn =
          if socket.assigns.type == "header",
            do: &Documents.create_header/1,
            else: &Documents.create_footer/1

        create_fn.(attrs)
      else
        Documents.update_header_footer(record, attrs)
      end

    case result do
      {:ok, saved} ->
        socket = assign(socket, record: saved, saving: false, error: nil, saved_flash: "Saved")

        if is_new do
          {:noreply, redirect(socket, to: hf_edit_path(socket.assigns.type, saved.uuid))}
        else
          {:noreply, socket}
        end

      {:error, _changeset} ->
        {:noreply, assign(socket, saving: false, error: "Save failed")}
    end
  end

  def handle_event("editor_not_ready", _params, socket) do
    {:noreply, put_flash(socket, :error, "Editor is still loading — please wait a moment and try again")}
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, saved_flash: nil)}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.editor_scripts />
    <div id="hf-hook-container" phx-hook="GrapesJSHFEditor" class="flex flex-col mx-auto px-4 py-6 gap-4">
      <%!-- Header bar --%>
      <div class="flex items-center justify-between sticky top-16 z-10 bg-base-100 py-2 -mt-2">
        <div class="flex items-center gap-3">
          <a href={hf_list_path(@type)} class="btn btn-ghost btn-sm btn-square">
            <span class="hero-arrow-left w-5 h-5" />
          </a>
          <div>
            <h1 class="text-xl font-bold">
              {if @live_action in [:header_new, :footer_new], do: "New", else: "Edit"} {String.capitalize(@type || "")}
            </h1>
            <p :if={@record} class="text-sm text-base-content/60">{@record.name}</p>
          </div>
        </div>
        <button class="btn btn-primary btn-sm" phx-click="request_save" disabled={@saving}>
          <span :if={@saving} class="loading loading-spinner loading-xs" />
          <span :if={not @saving} class="hero-check w-4 h-4" />
          {if @saving, do: "Saving...", else: "Save"}
        </button>
      </div>

      <%!-- Flash messages --%>
      <div :if={@saved_flash} class="alert alert-success" phx-click="dismiss_flash">
        <span class="hero-check-circle w-5 h-5" />
        <span>{@saved_flash}</span>
      </div>
      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span>{@error}</span>
      </div>

      <%!-- Main layout: Page preview + Elements panel + Settings sidebar --%>
      <div class="flex gap-4">
        <%!-- Page preview + Elements panel (left, inside phx-update="ignore") --%>
        <div class="flex-1 overflow-x-auto">
          <div id="hf-editor-area" phx-update="ignore" style="display:flex;width:100%;">
            <%!-- Page frame --%>
            <div
              id="hf-page-frame"
              data-type={@type}
              style="display:flex;flex-direction:column;width:794px;min-width:794px;height:1123px;background:#fff;box-shadow:0 2px 16px rgba(0,0,0,0.12);border-radius:4px;overflow:hidden;position:relative;"
            >
              <div id="hf-editor-loading" style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;z-index:10;background:#fff;">
                <span class="loading loading-spinner loading-md"></span>
              </div>

              <%= if @type == "header" do %>
                <div id="hf-editor" class="hf-mini-editor" style="height:95px;flex-shrink:0;flex-grow:0;overflow:hidden;"></div>
                <div id="hf-separator" style="border-top:2px dashed #cbd5e1;flex-shrink:0;"></div>
                <div id="hf-body-placeholder" style="flex:1 1 auto;background:repeating-linear-gradient(45deg,#f9fafb,#f9fafb 10px,#f3f4f6 10px,#f3f4f6 20px);display:flex;align-items:center;justify-content:center;pointer-events:none;user-select:none;">
                  <span style="color:#9ca3af;font-size:14px;font-style:italic;">Document body</span>
                </div>
              <% else %>
                <div id="hf-body-placeholder" style="flex:1 1 auto;background:repeating-linear-gradient(45deg,#f9fafb,#f9fafb 10px,#f3f4f6 10px,#f3f4f6 20px);display:flex;align-items:center;justify-content:center;pointer-events:none;user-select:none;">
                  <span style="color:#9ca3af;font-size:14px;font-style:italic;">Document body</span>
                </div>
                <div id="hf-separator" style="border-top:2px dashed #cbd5e1;flex-shrink:0;"></div>
                <div id="hf-editor" class="hf-mini-editor" style="height:95px;flex-shrink:0;flex-grow:0;overflow:hidden;"></div>
              <% end %>
            </div>

            <%!-- Elements panel (right of page, matching template editor) --%>
            <div id="hf-blocks-panel" class="bg-base-200 text-base-content border-l border-base-300" style="width:220px;min-width:220px;display:flex;flex-direction:column;">
              <div class="border-b border-base-300 text-base-content/70" style="padding:8px 12px;font-size:12px;font-weight:600;">
                Elements
              </div>
              <div id="hf-editor-blocks" style="flex:1;overflow-y:auto;"></div>
            </div>
          </div>
        </div>

        <%!-- Settings sidebar (right) --%>
        <div class="w-72 flex-shrink-0 space-y-4 sticky top-28 self-start max-h-[calc(100vh-8rem)] overflow-y-auto">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4 space-y-3">
              <h3 class="font-semibold text-sm">{String.capitalize(@type || "")} Settings</h3>

              <div class="form-control">
                <label class="label py-1"><span class="label-text text-xs">Name</span></label>
                <input
                  type="text"
                  id="hf-name"
                  class="input input-bordered input-sm w-full"
                  value={@record && @record.name || ""}
                />
              </div>

              <div class="form-control">
                <label class="label py-1"><span class="label-text text-xs">Height</span></label>
                <input
                  type="text"
                  id="hf-height"
                  class="input input-bordered input-sm w-full"
                  value={@record && @record.height || "25mm"}
                />
              </div>

              <div class="form-control">
                <label class="label py-1"><span class="label-text text-xs">Paper Size</span></label>
                <select id="hf-paper-size" class="select select-bordered select-sm w-full">
                  <option value="a4" selected={@paper_size == "a4"}>A4 (210 x 297 mm)</option>
                  <option value="letter" selected={@paper_size == "letter"}>US Letter (8.5 x 11 in)</option>
                  <option value="legal" selected={@paper_size == "legal"}>US Legal (8.5 x 14 in)</option>
                  <option value="tabloid" selected={@paper_size == "tabloid"}>Tabloid (11 x 17 in)</option>
                </select>
              </div>
            </div>
          </div>

          <p class="text-xs text-base-content/50">
            Drag elements from the Elements panel into the {String.downcase(@type || "")} area.
            The "Page #" block inserts page number placeholders for PDF output.
          </p>
        </div>
      </div>
    </div>

    <%!-- GrapesJS editor styles --%>
    <style>
      .hf-mini-editor .gjs-editor {
        background: #fff !important;
        position: relative !important;
      }
      .hf-mini-editor .gjs-cv-canvas {
        background: #fff !important;
        width: 100% !important;
        height: 100% !important;
        top: 0 !important;
        position: absolute !important;
      }
      .hf-mini-editor .gjs-pn-panels,
      .hf-mini-editor .gjs-com-badge,
      .hf-mini-editor .gjs-toolbar {
        display: none !important;
      }
      #hf-editor-blocks { padding: 4px; }
      #hf-editor-blocks .gjs-block-category .gjs-title {
        font-size: 11px !important; padding: 6px 8px !important;
        border-bottom: 1px solid oklch(var(--bc) / 0.1) !important;
      }
      #hf-editor-blocks .gjs-block {
        width: 100% !important; padding: 8px !important;
        min-height: 0 !important; justify-content: flex-start !important;
      }
    </style>
    """
  end
end
