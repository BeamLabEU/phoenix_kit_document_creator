defmodule PhoenixKitDocumentCreator.Web.DocumentEditorLive do
  @moduledoc """
  GrapesJS editor for documents with PDF export.

  Loads document content into GrapesJS, supports editing and exporting
  to PDF via ChromicPDF with header/footer support from the linked
  header_footer record.
  """
  use Phoenix.LiveView

  import PhoenixKitDocumentCreator.Web.Components.EditorScripts
  import PhoenixKitDocumentCreator.Web.Components.EditorPanel

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Paths
  alias PhoenixKitDocumentCreator.Web.EditorPdfHelpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       document: nil,
       saving: false,
       generating_pdf: false,
       error: nil,
       saved_flash: nil,
       show_media_selector: false
     )}
  end

  @impl true
  def handle_params(%{"uuid" => uuid}, _uri, socket) do
    case Documents.get_document(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Document not found")
         |> redirect(to: Paths.index())}

      document ->
        {:noreply,
         socket
         |> assign(
           page_title: document.name,
           document: document
         )
         |> maybe_load_project_data(document)
         |> push_hf_preview(:header, document)
         |> push_hf_preview(:footer, document)}
    end
  end

  defp maybe_load_project_data(socket, %{content_native: native, config: config})
       when is_map(native) do
    page_count = get_in(config || %{}, ["page_count"]) || "1"
    push_event(socket, "load-project", %{data: native, page_count: page_count})
  end

  defp maybe_load_project_data(socket, %{content_html: html, config: config})
       when is_binary(html) and html != "" do
    page_count = get_in(config || %{}, ["page_count"]) || "1"
    push_event(socket, "editor-set-content", %{html: html, page_count: page_count})
  end

  defp maybe_load_project_data(socket, _), do: socket

  # ── Save ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("request_save", _params, socket) do
    {:noreply, push_event(socket, "request-save-data", %{})}
  end

  def handle_event("save_document", params, socket) do
    native =
      case Jason.decode(Map.get(params, "native", "")) do
        {:ok, decoded} -> decoded
        _ -> nil
      end

    attrs = %{
      content_html: Map.get(params, "html", ""),
      content_css: Map.get(params, "css", ""),
      content_native: native
    }

    attrs =
      case Map.get(params, "name") do
        nil -> attrs
        "" -> attrs
        name -> Map.put(attrs, :name, name)
      end

    attrs =
      case Map.get(params, "page_count") do
        nil -> attrs
        "" -> attrs
        pc ->
          config = Map.get(attrs, :config) || socket.assigns.document.config || %{}
          Map.put(attrs, :config, Map.put(config, "page_count", pc))
      end

    socket = assign(socket, saving: true)

    case Documents.update_document(socket.assigns.document, attrs) do
      {:ok, document} ->
        # Store preview HTML for iframe thumbnail
        html = Map.get(params, "html", "")
        css = Map.get(params, "css", "")

        case EditorPdfHelpers.generate_thumbnail_html(html, css: css) do
          {:ok, thumb_html} -> Documents.update_document(document, %{thumbnail: thumb_html})
          _ -> :ok
        end

        {:noreply,
         assign(socket,
           document: document,
           saving: false,
           error: nil,
           saved_flash: "Document saved"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, saving: false, error: format_changeset_errors(changeset))}
    end
  end

  # ── PDF ────────────────────────────────────────────────────────────

  def handle_event("generate_pdf", _params, socket) do
    paper_size = get_in(socket.assigns.document.config, ["paper_size"]) || "a4"

    {:noreply,
     socket
     |> assign(generating_pdf: true, error: nil)
     |> push_event("request-content-for-pdf", %{paper_size: paper_size})}
  end

  def handle_event("generate_pdf_with_content", %{"html" => html} = params, socket) do
    doc = socket.assigns.document
    paper_size = Map.get(params, "paper_size", "a4")

    pdf_opts = [
      header_html: doc.header_html || "",
      header_css: doc.header_css || "",
      footer_html: doc.footer_html || "",
      footer_css: doc.footer_css || "",
      header_height: doc.header_height,
      footer_height: doc.footer_height,
      paper_size: paper_size
    ]

    try do
      case EditorPdfHelpers.generate_pdf(html, pdf_opts) do
        {:ok, pdf_binary} ->
          filename =
            (socket.assigns.document.name || "document")
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9]+/, "-")
            |> Kernel.<>(".pdf")

          {:noreply,
           socket
           |> assign(generating_pdf: false)
           |> push_event("download-pdf", %{base64: pdf_binary, filename: filename})}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             generating_pdf: false,
             error: "PDF generation failed: #{inspect(reason)}"
           )}
      end
    rescue
      _e ->
        {:noreply,
         assign(socket,
           generating_pdf: false,
           error: "PDF generation failed — Chrome may still be starting up, please try again"
         )}
    end
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, saved_flash: nil)}
  end

  # ── Media selector ────────────────────────────────────────────────

  def handle_event("open_media_selector", _params, socket) do
    {:noreply, assign(socket, show_media_selector: true)}
  end

  @impl true
  def handle_info({:media_selector_closed}, socket) do
    {:noreply, assign(socket, show_media_selector: false)}
  end

  def handle_info({:media_selected, file_uuids}, socket) do
    url =
      case file_uuids do
        [uuid | _] -> PhoenixKit.Modules.Storage.get_public_url_by_uuid(uuid)
        _ -> nil
      end

    socket = assign(socket, show_media_selector: false)

    if url do
      {:noreply, push_event(socket, "media_selected", %{url: url})}
    else
      {:noreply, socket}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} ->
      "#{Phoenix.Naming.humanize(field)}: #{Enum.join(errors, ", ")}"
    end)
    |> Enum.join(". ")
    |> then(&"Save failed — #{&1}")
  end

  defp push_hf_preview(socket, :header, doc) do
    push_event(socket, "update-hf-region", %{
      type: "header",
      html: doc.header_html || "",
      css: doc.header_css || "",
      height: doc.header_height || "25mm"
    })
  end

  defp push_hf_preview(socket, :footer, doc) do
    push_event(socket, "update-hf-region", %{
      type: "footer",
      html: doc.footer_html || "",
      css: doc.footer_css || "",
      height: doc.footer_height || "20mm"
    })
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.editor_scripts />
    <div class="flex flex-col mx-auto px-4 py-6 gap-4">
      <%!-- Header bar --%>
      <div class="flex items-center justify-between sticky top-16 z-10 bg-base-100 py-2 -mt-2">
        <div class="flex items-center gap-3">
          <a
            href={Paths.index()}
            class="btn btn-ghost btn-sm btn-square"
          >
            <span class="hero-arrow-left w-5 h-5" />
          </a>
          <div>
            <h1 class="text-xl font-bold">{@document && @document.name || "Document Editor"}</h1>
          </div>
        </div>
        <div class="flex gap-2">
          <button
            class="btn btn-ghost btn-sm"
            onclick={"document.getElementById('doc-wrapper').dispatchEvent(new Event('remove-page'))"}
          >
            <span class="hero-minus w-4 h-4" />
          </button>
          <button
            class="btn btn-ghost btn-sm"
            onclick={"document.getElementById('doc-wrapper').dispatchEvent(new Event('add-page'))"}
          >
            <span class="hero-plus w-4 h-4" />
          </button>
          <button
            class="btn btn-secondary btn-sm"
            phx-click="generate_pdf"
            disabled={@generating_pdf}
          >
            <span :if={@generating_pdf} class="loading loading-spinner loading-xs" />
            <span :if={not @generating_pdf} class="hero-document-arrow-down w-4 h-4" />
            {if @generating_pdf, do: "Generating...", else: "Export PDF"}
          </button>
          <button class="btn btn-primary btn-sm" phx-click="request_save" disabled={@saving}>
            <span :if={@saving} class="loading loading-spinner loading-xs" />
            <span :if={not @saving} class="hero-check w-4 h-4" />
            {if @saving, do: "Saving...", else: "Save"}
          </button>
        </div>
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

      <%!-- Main layout: Editor + sidebar --%>
      <div class="flex gap-4">
        <%!-- GrapesJS Editor --%>
        <.editor_panel
          id="doc"
          hook="GrapesJSDocumentEditor"
          save_event="save_document"
          template_vars={false}
        />

        <%!-- Sidebar --%>
        <div class="w-64 flex-shrink-0 space-y-4 sticky top-28 self-start max-h-[calc(100vh-8rem)] overflow-y-auto">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4 space-y-3">
              <h3 class="font-semibold text-sm">Document Settings</h3>

              <div class="form-control">
                <label class="label py-1"><span class="label-text text-xs">Name</span></label>
                <input
                  type="text"
                  id="doc-name"
                  class="input input-bordered input-sm w-full"
                  value={@document && @document.name || ""}
                />
              </div>

            </div>
          </div>

          <%!-- Template info --%>
          <div :if={@document && @document.template_uuid} class="card bg-base-100 shadow-xl">
            <div class="card-body p-4 space-y-2">
              <h3 class="font-semibold text-sm">Created from Template</h3>
              <p class="text-xs text-base-content/50">
                This document was created from a template. The content is now independent.
              </p>
            </div>
          </div>

          <%!-- Variable values (if created from template) --%>
          <div
            :if={@document && @document.variable_values != %{} and @document.variable_values != nil}
            class="card bg-base-100 shadow-xl"
          >
            <div class="card-body p-4 space-y-2">
              <h3 class="font-semibold text-sm">Variable Values Used</h3>
              <div :for={{key, value} <- @document.variable_values} class="text-xs">
                <span class="font-mono text-base-content/40">{"{{ #{key} }}"}</span>
                <span class="block text-base-content/70 truncate">{value}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <%!-- Media selector modal --%>
    <.live_component
      module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
      id="media-selector-modal"
      show={@show_media_selector}
      mode={:single}
      selected_uuids={[]}
      phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
    />

    """
  end

end
