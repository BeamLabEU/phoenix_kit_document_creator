defmodule PhoenixKitDocumentCreator.Web.TemplateEditorLive do
  @moduledoc """
  GrapesJS visual editor for templates with DB persistence.

  Supports `:new` and `:edit` actions. Saves content_html, content_css,
  and content_native (GrapesJS project data) to the templates table.
  Auto-extracts `{{ variable }}` placeholders from content.
  """
  use Phoenix.LiveView

  import PhoenixKitDocumentCreator.Web.Components.EditorScripts

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Paths
  alias PhoenixKitDocumentCreator.DocumentFormat
  alias PhoenixKitDocumentCreator.Web.EditorPdfHelpers

  @impl true
  def mount(_params, _session, socket) do
    {headers, footers} =
      if connected?(socket),
        do: {Documents.list_headers(), Documents.list_footers()},
        else: {[], []}

    {:ok,
     assign(socket,
       template: nil,
       changeset: nil,
       headers: headers,
       footers: footers,
       selected_header: nil,
       selected_footer: nil,
       detected_variables: [],
       saving: false,
       generating_pdf: false,
       error: nil,
       saved_flash: nil,
       show_media_selector: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    template = %PhoenixKitDocumentCreator.Schemas.Template{}
    changeset = PhoenixKitDocumentCreator.Schemas.Template.changeset(template, %{})

    socket
    |> assign(
      page_title: "New Template",
      template: template,
      changeset: changeset
    )
  end

  defp apply_action(socket, :edit, %{"uuid" => uuid}) do
    case Documents.get_template(uuid) do
      nil ->
        socket
        |> put_flash(:error, "Template not found")
        |> redirect(to: Paths.index())

      template ->
        changeset = PhoenixKitDocumentCreator.Schemas.Template.changeset(template, %{})
        variables = DocumentFormat.extract_variables(template.content_html || "")

        socket
        |> assign(
          page_title: "Edit: #{template.name}",
          template: template,
          changeset: changeset,
          detected_variables: variables,
          selected_header: find_in_list(socket.assigns.headers, template.header_uuid),
          selected_footer: find_in_list(socket.assigns.footers, template.footer_uuid)
        )
        |> maybe_load_project_data(template)
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

  defp maybe_load_project_data(socket, _template), do: socket

  # ── Save flow ──────────────────────────────────────────────────────

  @impl true
  def handle_event("request_save", _params, socket) do
    {:noreply,
     socket
     |> assign(saving: true)
     |> push_event("request-save-data", %{})}
  end

  def handle_event("save_template", params, socket) do
    html = Map.get(params, "html", "")
    css = Map.get(params, "css", "")

    native =
      case Jason.decode(Map.get(params, "native", "")) do
        {:ok, decoded} -> decoded
        _ -> nil
      end

    variables =
      DocumentFormat.extract_variables(html)
      |> Enum.map(fn name ->
        %{"name" => name, "label" => humanize(name), "type" => "text"}
      end)

    template_attrs = %{
      content_html: html,
      content_css: css,
      content_native: native,
      variables: variables
    }

    # Merge form fields if present
    template_attrs =
      template_attrs
      |> maybe_put(params, "name", :name)
      |> maybe_put(params, "description", :description)
      |> maybe_put(params, "status", :status)
      |> maybe_put(params, "header_uuid", :header_uuid)
      |> maybe_put(params, "footer_uuid", :footer_uuid)
      |> maybe_put_config(params, "paper_size")
      |> maybe_put_config(params, "page_count")

    result =
      case socket.assigns.live_action do
        :new -> Documents.create_template(template_attrs)
        :edit -> Documents.update_template(socket.assigns.template, template_attrs)
      end

    case result do
      {:ok, template} ->
        detected = DocumentFormat.extract_variables(html)

        socket =
          socket
          |> assign(
            template: template,
            changeset: PhoenixKitDocumentCreator.Schemas.Template.changeset(template, %{}),
            detected_variables: detected,
            saving: false,
            error: nil,
            saved_flash: "Template saved"
          )

        socket =
          if socket.assigns.live_action == :new do
            redirect(socket, to: Paths.template_edit(template.uuid))
          else
            socket
          end

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           changeset: changeset,
           saving: false,
           error: "Save failed — check the form fields"
         )}
    end
  end

  # ── PDF generation ─────────────────────────────────────────────────

  def handle_event("generate_pdf", _params, socket) do
    {:noreply,
     socket
     |> assign(generating_pdf: true, error: nil)
     |> push_event("request-content-for-pdf", %{})}
  end

  def handle_event("generate_pdf_with_content", %{"html" => html} = params, socket) do
    template = socket.assigns.template
    header = load_record(template.header_uuid)
    footer = load_record(template.footer_uuid)
    paper_size = Map.get(params, "paper_size", "a4")

    pdf_opts = [
      header_html: (header && header.html) || "",
      footer_html: (footer && footer.html) || "",
      paper_size: paper_size
    ]

    case EditorPdfHelpers.generate_pdf(html, pdf_opts) do
      {:ok, pdf_binary} ->
        filename =
          (socket.assigns.template.name || "template")
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
  end

  # ── Media selector ────────────────────────────────────────────────

  def handle_event("open_media_selector", _params, socket) do
    {:noreply, assign(socket, show_media_selector: true)}
  end

  # ── Form field changes ─────────────────────────────────────────────

  def handle_event("validate", %{"template" => template_params}, socket) do
    changeset =
      socket.assigns.template
      |> PhoenixKitDocumentCreator.Schemas.Template.changeset(template_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset)}
  end

  def handle_event("select_header", %{"header_uuid" => uuid}, socket) do
    {:noreply, assign(socket, selected_header: find_in_list(socket.assigns.headers, uuid))}
  end

  def handle_event("select_footer", %{"footer_uuid" => uuid}, socket) do
    {:noreply, assign(socket, selected_footer: find_in_list(socket.assigns.footers, uuid))}
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, saved_flash: nil)}
  end

  # ── Media selected (handle_info) ──────────────────────────────────

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

  defp load_record(uuid) when is_binary(uuid) and uuid != "" do
    Documents.get_header_footer(uuid)
  end

  defp load_record(_), do: nil

  defp maybe_put(attrs, params, form_key, attr_key) do
    case Map.get(params, form_key) do
      nil -> attrs
      "" -> attrs
      value -> Map.put(attrs, attr_key, value)
    end
  end

  defp maybe_put_config(attrs, params, key) do
    case Map.get(params, key) do
      nil -> attrs
      "" -> attrs
      value ->
        config = Map.get(attrs, :config) || %{}
        Map.put(attrs, :config, Map.put(config, key, value))
    end
  end

  defp hf_preview_html(html, css) do
    css_tag = if css && css != "", do: "<style>#{css}</style>", else: ""

    """
    <!DOCTYPE html>
    <html><head>
    <style>body{margin:0;padding:4px 8px;font-family:Helvetica,Arial,sans-serif;font-size:9px;overflow:hidden;}</style>
    #{css_tag}
    </head><body>#{html}</body></html>
    """
  end

  defp find_in_list(list, uuid) when is_binary(uuid) and uuid != "" do
    Enum.find(list, &(&1.uuid == uuid))
  end

  defp find_in_list(_, _), do: nil

  defp humanize(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
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
            <h1 class="text-xl font-bold">
              {if @live_action == :new, do: "New Template", else: "Edit Template"}
            </h1>
            <p :if={@template && @template.name} class="text-sm text-base-content/60">
              {@template.name}
            </p>
          </div>
        </div>
        <div class="flex gap-2">
          <button
            class="btn btn-ghost btn-sm"
            onclick={"document.getElementById('grapesjs-wrapper').dispatchEvent(new Event('remove-page'))"}
          >
            <span class="hero-minus w-4 h-4" />
          </button>
          <button
            class="btn btn-ghost btn-sm"
            onclick={"document.getElementById('grapesjs-wrapper').dispatchEvent(new Event('add-page'))"}
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
            {if @generating_pdf, do: "Generating...", else: "Preview PDF"}
          </button>
          <button class="btn btn-primary btn-sm" phx-click="request_save" disabled={@saving}>
            <span :if={@saving} class="loading loading-spinner loading-xs" />
            <span :if={not @saving} class="hero-check w-4 h-4" />
            {if @saving, do: "Saving...", else: "Save Template"}
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

      <%!-- Main layout: Editor + Settings sidebar --%>
      <div class="flex gap-4">
        <%!-- GrapesJS Editor (left, takes most space) --%>
        <div class="flex-1">
          <div id="grapesjs-wrapper" phx-hook="GrapesJSTemplateEditor" phx-update="ignore" style="display:flex;width:100%;height:100%;">
            <div id="editor-grapesjs" style="flex:1;"></div>
            <div id="grapesjs-right-panel" class="bg-base-200 text-base-content border-l border-base-300" style="width:220px;min-width:220px;display:flex;flex-direction:column;">
              <div class="border-b border-base-300 text-base-content/70" style="padding:8px 12px;font-size:12px;font-weight:600;">
                Document Elements
              </div>
              <div id="grapesjs-blocks-panel" style="flex:1;overflow-y:auto;"></div>
            </div>
          </div>
        </div>

        <%!-- Settings sidebar (right) --%>
        <div class="w-72 flex-shrink-0 space-y-4 sticky top-28 self-start max-h-[calc(100vh-8rem)] overflow-y-auto">
          <%!-- Template settings --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4 space-y-3">
              <h3 class="font-semibold text-sm">Template Settings</h3>

              <div class="form-control">
                <label class="label py-1"><span class="label-text text-xs">Name</span></label>
                <input
                  type="text"
                  id="template-name"
                  class="input input-bordered input-sm w-full"
                  value={if @template, do: @template.name || "", else: ""}
                  placeholder="Template name..."
                />
              </div>

              <div class="form-control">
                <label class="label py-1"><span class="label-text text-xs">Description</span></label>
                <textarea
                  id="template-description"
                  class="textarea textarea-bordered textarea-sm w-full"
                  rows="2"
                  placeholder="Optional description..."
                >{if @template, do: @template.description || "", else: ""}</textarea>
              </div>

              <div class="form-control">
                <label class="label py-1"><span class="label-text text-xs">Status</span></label>
                <select id="template-status" class="select select-bordered select-sm w-full">
                  <option value="draft" selected={@template && @template.status == "draft"}>
                    Draft
                  </option>
                  <option value="published" selected={@template && @template.status == "published"}>
                    Published
                  </option>
                  <option value="archived" selected={@template && @template.status == "archived"}>
                    Archived
                  </option>
                </select>
              </div>

              <div class="form-control">
                <label class="label py-1"><span class="label-text text-xs">Paper Size</span></label>
                <select id="template-paper-size" class="select select-bordered select-sm w-full">
                  <option
                    value="a4"
                    selected={@template && get_in(@template.config, ["paper_size"]) == "a4"}
                  >
                    A4 (210 × 297 mm)
                  </option>
                  <option
                    value="letter"
                    selected={@template && get_in(@template.config, ["paper_size"]) == "letter"}
                  >
                    US Letter (8.5 × 11 in)
                  </option>
                  <option
                    value="legal"
                    selected={@template && get_in(@template.config, ["paper_size"]) == "legal"}
                  >
                    US Legal (8.5 × 14 in)
                  </option>
                  <option
                    value="tabloid"
                    selected={@template && get_in(@template.config, ["paper_size"]) == "tabloid"}
                  >
                    Tabloid (11 × 17 in)
                  </option>
                </select>
              </div>

              <div class="form-control">
                <label class="label py-1">
                  <span class="label-text text-xs">Header</span>
                </label>
                <form phx-change="select_header">
                  <select name="header_uuid" id="template-header" class="select select-bordered select-sm w-full">
                    <option value="">None</option>
                    <option
                      :for={h <- @headers}
                      value={h.uuid}
                      selected={@template && @template.header_uuid == h.uuid}
                    >
                      {h.name}
                    </option>
                  </select>
                </form>
              </div>

              <%!-- Header preview --%>
              <div :if={@selected_header && @selected_header.html != ""} class="space-y-1">
                <iframe
                  srcdoc={hf_preview_html(@selected_header.html, @selected_header.css)}
                  class="w-full border border-base-300 rounded bg-white"
                  style="height:60px;pointer-events:none;"
                  sandbox=""
                  scrolling="no"
                />
                <a href={Paths.header_edit(@selected_header.uuid)} class="link link-primary text-xs" target="_blank">
                  Edit header
                </a>
              </div>

              <div class="form-control">
                <label class="label py-1">
                  <span class="label-text text-xs">Footer</span>
                </label>
                <form phx-change="select_footer">
                  <select name="footer_uuid" id="template-footer" class="select select-bordered select-sm w-full">
                    <option value="">None</option>
                    <option
                      :for={f <- @footers}
                      value={f.uuid}
                      selected={@template && @template.footer_uuid == f.uuid}
                    >
                      {f.name}
                    </option>
                  </select>
                </form>
              </div>

              <%!-- Footer preview --%>
              <div :if={@selected_footer && @selected_footer.html != ""} class="space-y-1">
                <iframe
                  srcdoc={hf_preview_html(@selected_footer.html, @selected_footer.css)}
                  class="w-full border border-base-300 rounded bg-white"
                  style="height:60px;pointer-events:none;"
                  sandbox=""
                  scrolling="no"
                />
                <a href={Paths.footer_edit(@selected_footer.uuid)} class="link link-primary text-xs" target="_blank">
                  Edit footer
                </a>
              </div>
            </div>
          </div>

          <%!-- Detected variables --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4 space-y-2">
              <h3 class="font-semibold text-sm">Detected Variables</h3>
              <div :if={@detected_variables == []} class="text-xs text-base-content/50">
                No <code>{"{{ variables }}"}</code> found yet. Save to detect.
              </div>
              <div :for={var <- @detected_variables} class="badge badge-ghost badge-sm">
                {"{{ #{var} }}"}
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

    <style>
      .gjs-off-prv { background-color: oklch(var(--color-base-200)) !important; color: oklch(var(--color-base-content)) !important; }
      #editor-grapesjs { --gjs-left-width: 0px; }
      #grapesjs-right-panel { position: sticky; top: 7rem; align-self: flex-start; max-height: calc(100vh - 8rem); overflow-y: auto; }
    </style>
    """
  end
end
