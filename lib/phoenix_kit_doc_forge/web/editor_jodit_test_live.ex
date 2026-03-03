defmodule PhoenixKitDocForge.Web.EditorJoditTestLive do
  @moduledoc """
  Test page for the Jodit 4.x WYSIWYG editor.

  Loads Jodit from CDN (UMD build), renders the full-featured editor,
  syncs content to `DocumentFormat`, and generates PDFs via ChromicPDF.
  No hooks — uses hidden form + inline JS for LiveView communication.
  """
  use Phoenix.LiveView

  alias PhoenixKitDocForge.DocumentFormat
  alias PhoenixKitDocForge.Web.EditorPdfHelpers

  @editor_info %{
    name: "Jodit",
    version: "4.6.4",
    license: "MIT",
    bundle: "~100KB gzipped",
    features: [
      "Zero dependencies",
      "Pure TypeScript",
      "Images (built-in, resize, placeholders)",
      "Source code editing",
      "File browser"
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Jodit Test",
       editor_info: @editor_info,
       editor_html: DocumentFormat.sample_html(),
       document_json: nil,
       generating: false,
       error: nil,
       last_generation_ms: nil,
       chrome_available:
         PhoenixKitDocForge.chromic_pdf_available?() and PhoenixKitDocForge.chrome_installed?()
     )}
  end

  @impl true
  def handle_event("sync_content", %{"editor_html" => html} = params, socket) do
    native_str = Map.get(params, "editor_native", "")
    native = if native_str != "", do: Jason.decode!(native_str), else: nil

    doc =
      DocumentFormat.new(html,
        native: native,
        native_format: "jodit_html",
        metadata: %{
          "editor" => "Jodit",
          "editor_version" => "4.6.4",
          "synced_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      )

    {:noreply,
     assign(socket,
       editor_html: html,
       document_json: DocumentFormat.to_json_string(doc)
     )}
  end

  def handle_event("export_json", _params, socket) do
    {:noreply, push_event(socket, "request-content", %{})}
  end

  def handle_event("insert_placeholder", _params, socket) do
    {:noreply, push_event(socket, "insert-placeholder", %{})}
  end

  def handle_event("generate_pdf", _params, socket) do
    {:noreply, push_event(socket, "request-content-for-pdf", %{})}
  end

  def handle_event("generate_pdf_with_content", %{"editor_html" => html} = params, socket) do
    socket = assign(socket, generating: true, error: nil)
    start = System.monotonic_time(:millisecond)

    case EditorPdfHelpers.generate_pdf(html,
           header_html: Map.get(params, "header_html", ""),
           footer_html: Map.get(params, "footer_html", "")
         ) do
      {:ok, pdf_binary} ->
        elapsed = System.monotonic_time(:millisecond) - start

        socket =
          socket
          |> assign(generating: false, last_generation_ms: elapsed)
          |> push_event("download-pdf", %{base64: pdf_binary, filename: "jodit-test.pdf"})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, generating: false, error: "PDF failed: #{inspect(reason)}")}
    end
  end

  def handle_event("reset_content", _params, socket) do
    {:noreply,
     socket
     |> assign(editor_html: DocumentFormat.sample_html(), document_json: nil)
     |> push_event("editor-set-content", %{html: DocumentFormat.sample_html()})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <%!-- Header Card --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="card-title text-2xl">{@editor_info.name} Editor Test</h2>
              <p class="text-sm text-base-content/60 mt-1">
                v{@editor_info.version} | {@editor_info.license} | {@editor_info.bundle}
              </p>
            </div>
            <div :if={@last_generation_ms} class="text-right">
              <div class="stat-value text-lg">{@last_generation_ms}ms</div>
              <div class="text-xs text-base-content/60">PDF generation</div>
            </div>
          </div>
          <div class="flex flex-wrap gap-1 mt-2">
            <span :for={feat <- @editor_info.features} class="badge badge-sm badge-ghost">
              {feat}
            </span>
          </div>
        </div>
      </div>

      <%!-- Chrome Warning --%>
      <div :if={not @chrome_available} class="alert alert-warning">
        <span class="hero-exclamation-triangle w-5 h-5" />
        <div>
          <p class="font-semibold">Chrome/ChromicPDF not available</p>
          <p class="text-sm mt-1">
            PDF generation requires <code>chromic_pdf ~> 1.17</code> and Chrome installed.
            The editor still works for content editing and JSON export.
          </p>
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span>{@error}</span>
      </div>

      <%!-- Two-column layout --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Editor (left, 2/3) --%>
        <div class="lg:col-span-2">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="card-title text-sm">Editor</h3>

              <div id="jodit-editor-wrapper" phx-update="ignore">
                <textarea
                  id="editor-jodit"
                  data-initial-content={@editor_html}
                  style="display: none;"
                ></textarea>
              </div>

              <div class="flex flex-wrap gap-2 mt-4">
                <button class="btn btn-primary btn-sm" phx-click="export_json">
                  Export JSON
                </button>
                <button
                  class="btn btn-secondary btn-sm"
                  phx-click="generate_pdf"
                  disabled={@generating or not @chrome_available}
                >
                  <span :if={@generating} class="loading loading-spinner loading-xs" />
                  {if @generating, do: "Generating...", else: "Generate PDF"}
                </button>
                <button class="btn btn-outline btn-sm" phx-click="insert_placeholder">
                  Insert Placeholder
                </button>
                <button class="btn btn-ghost btn-sm" phx-click="reset_content">
                  Reset
                </button>
              </div>

              <%!-- PDF Header/Footer Options --%>
              <details class="mt-3">
                <summary class="cursor-pointer text-sm font-medium text-base-content/70 hover:text-base-content">
                  PDF Header & Footer Options
                </summary>
                <div class="mt-3 space-y-4">
                  <div>
                    <div class="label"><span class="label-text text-xs font-medium">Header Design</span></div>
                    <div id="jodit-header-editor-wrapper" phx-update="ignore">
                      <textarea id="jodit-header-editor" style="display:none;"></textarea>
                    </div>
                  </div>
                  <div>
                    <div class="label"><span class="label-text text-xs font-medium">Footer Design</span></div>
                    <div id="jodit-footer-editor-wrapper" phx-update="ignore">
                      <textarea id="jodit-footer-editor" style="display:none;"></textarea>
                    </div>
                  </div>
                  <p class="text-xs text-base-content/50">
                    Images float left so text flows beside them. Use a table for multi-column layouts.
                  </p>
                </div>
              </details>
            </div>
          </div>
        </div>

        <%!-- JSON Output (right, 1/3) --%>
        <div class="lg:col-span-1">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="card-title text-sm">Document Format (JSON)</h3>
              <div class="bg-base-200 rounded-lg p-3 mt-2 overflow-auto max-h-[600px]">
                <pre class="text-xs font-mono whitespace-pre-wrap">{@document_json || "Click \"Export JSON\" to sync editor content"}</pre>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Hidden forms for content sync --%>
      <form id="jodit-sync-form" phx-submit="sync_content" class="hidden">
        <input type="hidden" name="editor_html" id="jodit-sync-html" value="" />
        <input type="hidden" name="editor_native" id="jodit-sync-native" value="" />
        <button type="submit" id="jodit-sync-submit">sync</button>
      </form>

      <form id="jodit-pdf-form" phx-submit="generate_pdf_with_content" class="hidden">
        <input type="hidden" name="editor_html" id="jodit-pdf-html" value="" />
        <input type="hidden" name="header_html" id="jodit-pdf-header" value="" />
        <input type="hidden" name="footer_html" id="jodit-pdf-footer" value="" />
        <button type="submit" id="jodit-pdf-submit">pdf</button>
      </form>
    </div>

    <%!-- CDN resources --%>
    <div id="jodit-cdn-resources" phx-update="ignore">
      <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/jodit@4.6.4/es2021/jodit.min.css" />
      <script src="https://cdn.jsdelivr.net/npm/jodit@4.6.4/es2021/jodit.min.js">
      </script>
    </div>

    <%!-- Editor init + event wiring --%>
    <div id="jodit-init-script" phx-update="ignore"><script>
      (function() {
        if (window.__documentCreatorJoditInit) return;
        window.__documentCreatorJoditInit = true;

        function initJodit() {
          var container = document.getElementById("editor-jodit");
          if (!container) { setTimeout(initJodit, 100); return; }
          if (typeof Jodit === "undefined") { setTimeout(initJodit, 100); return; }

          var editor = Jodit.make("#editor-jodit", {
            height: 450,
            toolbarButtonSize: "small",
            showCharsCounter: false,
            showWordsCounter: false,
            showXPathInStatusbar: false,
            buttons: [
              "bold", "italic", "underline", "strikethrough", "|",
              "ul", "ol", "|",
              "font", "fontsize", "paragraph", "|",
              "image", "table", "link", "hr", "|",
              "left", "center", "right", "justify", "|",
              "undo", "redo", "|",
              "eraser", "source", "fullsize"
            ],
            uploader: {
              insertImageAsBase64URI: true
            },
            imageDefaultWidth: 300,
            allowResizeTags: new Set(["img", "iframe", "table"]),
            resizer: {
              showSize: true,
              useAspectRatio: true,
              forImageChangeAttributes: true,
              min_width: 50,
              min_height: 50
            }
          });

          // Set initial content from data attribute
          var initial = container.getAttribute("data-initial-content");
          if (initial) {
            editor.value = initial;
          }

          window.__documentCreatorJoditInstance = editor;

          // --- Mini editors for header/footer (lazy init on details open) ---
          var miniJoditConfig = {
            height: 120,
            toolbarButtonSize: "xsmall",
            showCharsCounter: false,
            showWordsCounter: false,
            showXPathInStatusbar: false,
            buttons: ["bold", "italic", "underline", "|", "left", "center", "right", "|", "image", "table", "link"],
            uploader: { insertImageAsBase64URI: true },
            imageDefaultWidth: 50,
            placeholder: "",
            createAttributes: {
              img: { style: "float:left;margin-right:8px;margin-bottom:4px;max-height:60px;width:auto;" }
            }
          };

          // Defer init until <details> is opened so toolbar renders at correct width
          var detailsEl = document.querySelector("#jodit-editor-wrapper")?.closest(".card-body")?.querySelector("details");
          if (detailsEl) {
            detailsEl.addEventListener("toggle", function initMiniJodit() {
              if (!detailsEl.open || window.__joditHeaderEditor) return;
              var headerEl = document.getElementById("jodit-header-editor");
              if (headerEl) {
                window.__joditHeaderEditor = Jodit.make("#jodit-header-editor", Object.assign({}, miniJoditConfig, {
                  placeholder: "Design your PDF header..."
                }));
              }
              var footerEl = document.getElementById("jodit-footer-editor");
              if (footerEl) {
                window.__joditFooterEditor = Jodit.make("#jodit-footer-editor", Object.assign({}, miniJoditConfig, {
                  placeholder: "Design your PDF footer..."
                }));
              }
            });
          }

          // Image placeholder insertion
          window.__joditInsertPlaceholder = function() {
            var name = prompt("Placeholder variable name (e.g. company_logo):");
            if (!name) return;
            name = name.trim().replace(/[^a-zA-Z0-9_]/g, "_");
            if (!name) return;

            var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120">' +
              '<rect width="200" height="120" fill="#f8f9fa" stroke="#6b7280" stroke-width="2" stroke-dasharray="8,4" rx="8"/>' +
              '<text x="100" y="50" text-anchor="middle" fill="#6b7280" font-family="sans-serif" font-size="12" font-weight="600">Image Placeholder</text>' +
              '<text x="100" y="74" text-anchor="middle" fill="#9ca3af" font-family="monospace" font-size="11">{{ ' + name + ' }}</text></svg>';
            var dataUri = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
            editor.selection.insertHTML('<img src="' + dataUri + '" alt="{{ ' + name + ' }}" title="Image placeholder: ' + name + '" width="200" height="120" style="display:block;" />');
          };

          // Handle export JSON request
          window.addEventListener("phx:request-content", function() {
            var html = editor.value;
            document.getElementById("jodit-sync-html").value = html;
            document.getElementById("jodit-sync-native").value = "";
            document.getElementById("jodit-sync-submit").click();
          });

          // Handle PDF generation request
          window.addEventListener("phx:request-content-for-pdf", function() {
            var html = editor.value;
            document.getElementById("jodit-pdf-html").value = html;
            document.getElementById("jodit-pdf-header").value = window.__joditHeaderEditor ? window.__joditHeaderEditor.value : "";
            document.getElementById("jodit-pdf-footer").value = window.__joditFooterEditor ? window.__joditFooterEditor.value : "";
            document.getElementById("jodit-pdf-submit").click();
          });

          // Handle content reset from server
          window.addEventListener("phx:editor-set-content", function(e) {
            editor.value = e.detail.html;
          });

          // Handle placeholder insertion from server
          window.addEventListener("phx:insert-placeholder", function() {
            if (window.__joditInsertPlaceholder) window.__joditInsertPlaceholder();
          });
        }

        // Start initialization
        if (document.readyState === "loading") {
          document.addEventListener("DOMContentLoaded", initJodit);
        } else {
          initJodit();
        }

        // Cleanup on LiveView navigation
        window.addEventListener("phx:page-loading-start", function() {
          if (window.__documentCreatorJoditInstance) {
            window.__documentCreatorJoditInstance.destruct();
          }
          window.__documentCreatorJoditInit = false;
          window.__documentCreatorJoditInstance = null;
          if (window.__joditHeaderEditor) { window.__joditHeaderEditor.destruct(); window.__joditHeaderEditor = null; }
          if (window.__joditFooterEditor) { window.__joditFooterEditor.destruct(); window.__joditFooterEditor = null; }
        });
      })();
    </script></div>

    <%!-- Download handler --%>
    <div id="jodit-download-script" phx-update="ignore"><script>
      (function() {
        if (window.__documentCreatorDownloadInitJodit) return;
        window.__documentCreatorDownloadInitJodit = true;
        window.addEventListener("phx:download-pdf", function(e) {
          var bin = atob(e.detail.base64);
          var bytes = new Uint8Array(bin.length);
          for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          var blob = new Blob([bytes], { type: "application/pdf" });
          var url = URL.createObjectURL(blob);
          var a = document.createElement("a");
          a.href = url;
          a.download = e.detail.filename || "document.pdf";
          a.style.display = "none";
          document.body.appendChild(a);
          a.click();
          setTimeout(function() { a.remove(); URL.revokeObjectURL(url); }, 100);
        });
      })();
    </script></div>
    """
  end
end
