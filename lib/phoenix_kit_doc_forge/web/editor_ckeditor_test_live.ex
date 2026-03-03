defmodule PhoenixKitDocForge.Web.EditorCkeditorTestLive do
  @moduledoc """
  Test page for CKEditor 5 WYSIWYG editor.

  Loads CKEditor 5 Classic from CDN (UMD build), renders a 2-column layout with
  the editor on the left and the standardized JSON output on the right.
  Uses hidden form + inline JS for LiveView communication (no hooks).

  CKEditor 5 CDN requires `licenseKey: 'GPL'` for open-source usage.
  """
  use Phoenix.LiveView

  alias PhoenixKitDocForge.DocumentFormat
  alias PhoenixKitDocForge.Web.EditorPdfHelpers

  @editor_info %{
    name: "CKEditor 5",
    version: "44.3.0",
    license: "GPL / Commercial (from $144/mo)",
    bundle: "~300KB gzipped",
    features: [
      "Tables with toolbar",
      "Images (insert URL, resize)",
      "Block quotes",
      "Alignment",
      "License key required for CDN"
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "CKEditor 5 Test",
       editor_info: @editor_info,
       json_output: nil,
       generating_pdf: false,
       error: nil,
       sample_html: DocumentFormat.sample_html()
     )}
  end

  @impl true
  def handle_event("sync_content", %{"html" => html}, socket) do
    doc = DocumentFormat.new(html, native_format: "ckeditor-html")
    json = DocumentFormat.to_json_string(doc)
    {:noreply, assign(socket, json_output: json, error: nil)}
  end

  def handle_event("export_json", _params, socket) do
    {:noreply, push_event(socket, "request-content", %{})}
  end

  def handle_event("insert_placeholder", _params, socket) do
    {:noreply, push_event(socket, "insert-placeholder", %{})}
  end

  def handle_event("generate_pdf", _params, socket) do
    {:noreply,
     socket
     |> assign(generating_pdf: true, error: nil)
     |> push_event("request-content-for-pdf", %{})}
  end

  def handle_event("generate_pdf_with_content", %{"html" => html} = params, socket) do
    case EditorPdfHelpers.generate_pdf(html,
           header_html: Map.get(params, "header_html", ""),
           footer_html: Map.get(params, "footer_html", "")
         ) do
      {:ok, pdf_binary} ->
        {:noreply,
         socket
         |> assign(generating_pdf: false)
         |> push_event("download-pdf", %{
           base64: pdf_binary,
           filename: "ckeditor-test.pdf"
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           generating_pdf: false,
           error: "PDF generation failed: #{inspect(reason)}"
         )}
    end
  end

  def handle_event("reset_content", _params, socket) do
    {:noreply, push_event(socket, "editor-set-content", %{html: DocumentFormat.sample_html()})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-7xl px-4 py-6 gap-6">
      <%!-- Header --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="card-title text-2xl">{@editor_info.name} Test</h2>
              <p class="text-sm text-base-content/60">v{@editor_info.version} | {@editor_info.license} | {@editor_info.bundle}</p>
            </div>
            <a
              href="./"
              data-phx-link="redirect"
              data-phx-link-state="push"
              class="btn btn-ghost btn-sm"
            >
              Back to Editors
            </a>
          </div>
          <div class="flex flex-wrap gap-1 mt-2">
            <span :for={feat <- @editor_info.features} class="badge badge-sm badge-outline">{feat}</span>
          </div>
        </div>
      </div>

      <%!-- GPL License Note --%>
      <div class="alert alert-info">
        <span class="hero-information-circle w-5 h-5" />
        <div>
          <p class="font-semibold">CKEditor 5 CDN License Note</p>
          <p class="text-sm">
            CKEditor 5 CDN builds require a <code class="bg-base-200 px-1 rounded">licenseKey</code>.
            This test page uses <code class="bg-base-200 px-1 rounded">'GPL'</code> for open-source evaluation.
            Commercial use requires a paid license starting at $144/month.
          </p>
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span>{@error}</span>
      </div>

      <%!-- Action Buttons --%>
      <div class="flex gap-2">
        <button class="btn btn-ghost btn-sm" phx-click="reset_content">
          <span class="hero-arrow-path w-4 h-4" /> Reset Content
        </button>
        <button class="btn btn-primary btn-sm" phx-click="export_json">
          <span class="hero-code-bracket w-4 h-4" /> Export JSON
        </button>
        <button class="btn btn-secondary btn-sm" phx-click="generate_pdf" disabled={@generating_pdf}>
          <span :if={@generating_pdf} class="loading loading-spinner loading-xs" />
          <span :if={not @generating_pdf} class="hero-document-arrow-down w-4 h-4" />
          {if @generating_pdf, do: "Generating...", else: "Generate PDF"}
        </button>
        <button class="btn btn-outline btn-sm" phx-click="insert_placeholder">
          Insert Placeholder
        </button>
      </div>

      <%!-- PDF Header/Footer Options --%>
      <details>
        <summary class="cursor-pointer text-sm font-medium text-base-content/70 hover:text-base-content">
          PDF Header & Footer Options
        </summary>
        <div class="mt-3 space-y-4">
          <div>
            <div class="label"><span class="label-text text-xs font-medium">Header Design</span></div>
            <div id="ckeditor-header-editor-wrapper" phx-update="ignore">
              <div id="ckeditor-header-editor"></div>
            </div>
          </div>
          <div>
            <div class="label"><span class="label-text text-xs font-medium">Footer Design</span></div>
            <div id="ckeditor-footer-editor-wrapper" phx-update="ignore">
              <div id="ckeditor-footer-editor"></div>
            </div>
          </div>
          <p class="text-xs text-base-content/50">
            Images float left so text flows beside them. Use a table for multi-column layouts.
          </p>
        </div>
      </details>

      <%!-- 2-Column Layout --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <%!-- Editor Column --%>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="card-title text-sm">Editor</h3>
            <div id="ckeditor-wrapper" phx-update="ignore">
              <div
                id="editor-ckeditor"
                data-initial-content={@sample_html}
              ></div>
            </div>
          </div>
        </div>

        <%!-- JSON Output Column --%>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="card-title text-sm">Standardized Document Format (JSON)</h3>
            <div :if={@json_output} class="mockup-code text-xs overflow-auto max-h-[600px]">
              <pre class="px-4"><code>{@json_output}</code></pre>
            </div>
            <div :if={is_nil(@json_output)} class="text-center py-12 text-base-content/40">
              <span class="hero-code-bracket-square w-12 h-12 mx-auto mb-2" />
              <p>Click "Export JSON" to see the standardized document format</p>
            </div>
          </div>
        </div>
      </div>
    </div>

    <%!-- Hidden form for JS -> LiveView communication --%>
    <form id="ckeditor-sync-form" phx-submit="sync_content" class="hidden" phx-update="ignore">
      <input type="hidden" name="html" id="ckeditor-sync-html" value="" />
      <button type="submit" id="ckeditor-sync-submit">sync</button>
    </form>
    <form id="ckeditor-pdf-form" phx-submit="generate_pdf_with_content" class="hidden" phx-update="ignore">
      <input type="hidden" name="html" id="ckeditor-pdf-html" value="" />
      <input type="hidden" name="header_html" id="ckeditor-pdf-header" value="" />
      <input type="hidden" name="footer_html" id="ckeditor-pdf-footer" value="" />
      <button type="submit" id="ckeditor-pdf-submit">pdf</button>
    </form>

    <style>
      #ckeditor-header-editor-wrapper .ck-editor__editable,
      #ckeditor-footer-editor-wrapper .ck-editor__editable {
        min-height: 80px !important;
        max-height: 120px !important;
        overflow-y: auto !important;
        font-size: 12px;
      }
      #ckeditor-header-editor-wrapper .ck-editor__editable img,
      #ckeditor-footer-editor-wrapper .ck-editor__editable img {
        max-height: 50px;
        width: auto;
        float: left;
        margin-right: 8px;
        margin-bottom: 4px;
      }
    </style>

    <%!-- CDN + Init Script --%>
    <div id="ckeditor-cdn-block" phx-update="ignore">
      <link rel="stylesheet" href="https://cdn.ckeditor.com/ckeditor5/44.3.0/ckeditor5.css" />
      <script src="https://cdn.ckeditor.com/ckeditor5/44.3.0/ckeditor5.umd.js"></script>
      <script>
        (function() {
          if (window.__documentCreatorCkeditorInit) return;
          window.__documentCreatorCkeditorInit = true;

          function initCKEditor() {
            var container = document.querySelector('#editor-ckeditor');
            if (!container || !window.CKEDITOR) {
              setTimeout(initCKEditor, 100);
              return;
            }

            var initialContent = container.getAttribute('data-initial-content') || '';

            var CKE = CKEDITOR;
            var ClassicEditor = CKE.ClassicEditor;
            var Essentials = CKE.Essentials;
            var Bold = CKE.Bold;
            var Italic = CKE.Italic;
            var Heading = CKE.Heading;
            var Link = CKE.Link;
            var List = CKE.List;
            var Table = CKE.Table;
            var TableToolbar = CKE.TableToolbar;
            var Paragraph = CKE.Paragraph;
            var BlockQuote = CKE.BlockQuote;
            var Undo = CKE.Undo;
            var Indent = CKE.Indent;
            var HorizontalLine = CKE.HorizontalLine;
            var Alignment = CKE.Alignment;
            var ImageInline = CKE.ImageInline;
            var ImageBlock = CKE.ImageBlock;
            var ImageToolbar = CKE.ImageToolbar;
            var ImageResize = CKE.ImageResize;
            var ImageInsertViaUrl = CKE.ImageInsertViaUrl;

            // Collect only available image plugins (some may not exist in this build)
            var imagePlugins = [ImageInline, ImageBlock, ImageToolbar, ImageResize, ImageInsertViaUrl].filter(Boolean);

            ClassicEditor.create(container, {
              licenseKey: 'GPL',
              plugins: [Essentials, Bold, Italic, Heading, Link, List, Table, TableToolbar, Paragraph, BlockQuote, Undo, Indent, HorizontalLine, Alignment].concat(imagePlugins),
              toolbar: ['heading', '|', 'bold', 'italic', 'link', '|', 'bulletedList', 'numberedList', '|', 'insertImage', 'insertTable', 'blockQuote', 'horizontalLine', '|', 'alignment', '|', 'undo', 'redo'],
              image: {
                toolbar: ['imageTextAlternative', '|', 'resizeImage:50', 'resizeImage:75', 'resizeImage:original'],
                resizeUnit: '%',
                resizeOptions: [
                  { name: 'resizeImage:original', value: null, label: 'Original' },
                  { name: 'resizeImage:50', value: '50', label: '50%' },
                  { name: 'resizeImage:75', value: '75', label: '75%' }
                ],
                insert: { type: 'auto' }
              },
              table: {
                contentToolbar: ['tableColumn', 'tableRow', 'mergeTableCells']
              },
              initialData: initialContent
            }).then(function(editor) {
              window.__ckEditor = editor;

              // Image placeholder insertion
              window.__ckInsertPlaceholder = function() {
                var name = prompt("Placeholder variable name (e.g. company_logo):");
                if (!name) return;
                name = name.trim().replace(/[^a-zA-Z0-9_]/g, "_");
                if (!name) return;

                var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120">' +
                  '<rect width="200" height="120" fill="#f8f9fa" stroke="#6b7280" stroke-width="2" stroke-dasharray="8,4" rx="8"/>' +
                  '<text x="100" y="50" text-anchor="middle" fill="#6b7280" font-family="sans-serif" font-size="12" font-weight="600">Image Placeholder</text>' +
                  '<text x="100" y="74" text-anchor="middle" fill="#9ca3af" font-family="monospace" font-size="11">{{ ' + name + ' }}</text></svg>';
                var dataUri = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);

                editor.model.change(function(writer) {
                  var imageElement = writer.createElement('imageBlock', {
                    src: dataUri,
                    alt: '{{ ' + name + ' }}'
                  });
                  editor.model.insertContent(imageElement);
                });
              };
            })
            // --- Mini editors for header/footer (lazy init on details open) ---
            .then(function() {
            var miniPlugins = [Essentials, Bold, Italic, Link, Paragraph, Alignment].concat([ImageInline, ImageInsertViaUrl, typeof Table !== 'undefined' ? Table : null].filter(Boolean));
            var miniToolbar = ['bold', 'italic', 'link', '|', 'alignment', '|', 'insertImage'].concat(typeof Table !== 'undefined' ? ['|', 'insertTable'] : []);
            var miniConfig = {
              licenseKey: 'GPL',
              plugins: miniPlugins,
              toolbar: miniToolbar,
              image: { insert: { type: 'auto' } }
            };

            var ckDetails = document.getElementById("ckeditor-header-editor-wrapper")?.closest("details");
            if (ckDetails) {
              ckDetails.addEventListener("toggle", function() {
                if (!ckDetails.open || window.__ckHeaderEditor) return;
                var headerEl = document.querySelector('#ckeditor-header-editor');
                if (headerEl) {
                  ClassicEditor.create(headerEl, Object.assign({}, miniConfig, {
                    placeholder: 'Design your PDF header...'
                  })).then(function(ed) { window.__ckHeaderEditor = ed; }).catch(function(e) { console.error('CK header init failed:', e); });
                }
                var footerEl = document.querySelector('#ckeditor-footer-editor');
                if (footerEl) {
                  ClassicEditor.create(footerEl, Object.assign({}, miniConfig, {
                    placeholder: 'Design your PDF footer...'
                  })).then(function(ed) { window.__ckFooterEditor = ed; }).catch(function(e) { console.error('CK footer init failed:', e); });
                }
              });
            }
            }).catch(function(err) {
              console.error('CKEditor init failed:', err);
            });
          }

          // Listen for export JSON request
          window.addEventListener('phx:request-content', function() {
            if (!window.__ckEditor) return;
            var html = window.__ckEditor.getData();
            document.getElementById('ckeditor-sync-html').value = html;
            document.getElementById('ckeditor-sync-submit').click();
          });

          // Listen for PDF generation request
          window.addEventListener('phx:request-content-for-pdf', function() {
            if (!window.__ckEditor) return;
            var html = window.__ckEditor.getData();
            document.getElementById('ckeditor-pdf-html').value = html;
            document.getElementById('ckeditor-pdf-header').value = window.__ckHeaderEditor ? window.__ckHeaderEditor.getData() : '';
            document.getElementById('ckeditor-pdf-footer').value = window.__ckFooterEditor ? window.__ckFooterEditor.getData() : '';
            document.getElementById('ckeditor-pdf-submit').click();
          });

          // Listen for set content request
          window.addEventListener('phx:editor-set-content', function(e) {
            if (!window.__ckEditor) return;
            window.__ckEditor.setData(e.detail.html || '');
          });

          // Listen for placeholder insertion request
          window.addEventListener('phx:insert-placeholder', function() {
            if (window.__ckInsertPlaceholder) window.__ckInsertPlaceholder();
          });

          // Download PDF handler
          window.addEventListener('phx:download-pdf', function(e) {
            var bin = atob(e.detail.base64);
            var bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            var blob = new Blob([bytes], { type: 'application/pdf' });
            var url = URL.createObjectURL(blob);
            var a = document.createElement('a');
            a.href = url;
            a.download = e.detail.filename || 'document.pdf';
            a.style.display = 'none';
            document.body.appendChild(a);
            a.click();
            setTimeout(function() { a.remove(); URL.revokeObjectURL(url); }, 100);
          });

          initCKEditor();
        })();
      </script>
    </div>
    """
  end
end
