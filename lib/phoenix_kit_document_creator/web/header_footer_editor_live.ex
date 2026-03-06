defmodule PhoenixKitDocumentCreator.Web.HeaderFooterEditorLive do
  @moduledoc """
  Shared editor page for header and footer designs.

  Uses `live_action` to determine context:
  - `:header_new` / `:footer_new` — opens editor with an unsaved in-memory record
  - `:header_edit` / `:footer_edit` — loads existing record by UUID for editing

  The first save of a new record persists it and redirects to the edit URL.
  Contains a single mini GrapesJS editor for visual layout design.
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
    record = %HeaderFooter{type: type, name: "Untitled #{String.capitalize(type)}", height: "25mm"}

    socket
    |> assign(
      page_title: "New #{String.capitalize(type)}",
      record: record,
      type: type
    )
    |> push_event("init-hf-editor", %{native: nil})
  end

  defp load_record(socket, type, %{"uuid" => uuid}) do
    case Documents.get_header_footer(uuid) do
      nil ->
        socket
        |> put_flash(:error, "#{String.capitalize(type)} not found")
        |> redirect(to: hf_list_path(type))

      record ->
        socket
        |> assign(
          page_title: "Edit: #{record.name}",
          record: record,
          type: type
        )
        |> push_event("init-hf-editor", %{
          native: record.native
        })
    end
  end

  defp hf_list_path("header"), do: Paths.headers()
  defp hf_list_path("footer"), do: Paths.footers()

  defp hf_edit_path("header", uuid), do: Paths.header_edit(uuid)
  defp hf_edit_path("footer", uuid), do: Paths.footer_edit(uuid)

  # ── Save ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("request_save", _params, socket) do
    {:noreply,
     socket
     |> assign(saving: true)
     |> push_event("request-hf-save-data", %{})}
  end

  def handle_event("save_record", params, socket) do
    record = socket.assigns.record

    native =
      case Jason.decode(Map.get(params, "native", "")) do
        {:ok, decoded} -> decoded
        _ -> nil
      end

    attrs = %{
      name: Map.get(params, "name", record.name),
      html: Map.get(params, "html", ""),
      css: Map.get(params, "css", ""),
      native: native,
      height: Map.get(params, "height", record.height)
    }

    is_new = socket.assigns.live_action in [:header_new, :footer_new]

    result =
      if is_new do
        create_fn = if socket.assigns.type == "header", do: &Documents.create_header/1, else: &Documents.create_footer/1
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

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, saved_flash: nil)}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.editor_scripts />
    <div id="hf-hook-container" phx-hook="GrapesJSHFEditor" class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <%!-- Header bar --%>
      <div class="flex items-center justify-between">
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

      <%!-- Settings row --%>
      <div :if={@record} class="card bg-base-100 shadow-xl">
        <div class="card-body p-4">
          <div class="flex gap-4 items-end">
            <div class="form-control flex-1">
              <label class="label py-1"><span class="label-text text-xs">Name</span></label>
              <input
                type="text"
                id="hf-name"
                class="input input-bordered input-sm w-full"
                value={@record.name}
              />
            </div>
            <div class="form-control w-28">
              <label class="label py-1"><span class="label-text text-xs">Height</span></label>
              <input
                type="text"
                id="hf-height"
                class="input input-bordered input-sm"
                value={@record.height}
              />
            </div>
          </div>
        </div>
      </div>

      <%!-- Editor --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body p-4 space-y-2">
          <h3 class="font-semibold text-sm">{String.capitalize(@type || "")} Design</h3>
          <div
            id="hf-editor-wrapper"
            phx-update="ignore"
            style="display:flex;border:1px solid oklch(var(--bc) / 0.2);border-radius:0.5rem;overflow:hidden;position:relative;"
          >
            <div id="hf-editor-loading" style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;z-index:10;background:oklch(var(--b1, 1 0 0));">
              <span class="loading loading-spinner loading-md"></span>
            </div>
            <div id="hf-editor" class="hf-mini-editor" style="flex:1;height:200px;"></div>
            <div
              id="hf-editor-blocks"
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
end
