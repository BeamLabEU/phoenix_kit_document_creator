defmodule PhoenixKitDocForge.Web.EditorQuillTestLive do
  @moduledoc """
  Test page for the Quill 2.x WYSIWYG editor.

  Loads Quill from CDN (UMD build), renders the Snow theme editor,
  syncs content to `DocumentFormat`, and generates PDFs via ChromicPDF.
  No hooks — uses hidden form + inline JS for LiveView communication.
  """
  use Phoenix.LiveView

  alias PhoenixKitDocForge.DocumentFormat
  alias PhoenixKitDocForge.Web.EditorPdfHelpers

  @editor_info %{
    name: "Quill",
    version: "2.0.3",
    license: "BSD 3-Clause",
    bundle: "~40KB gzipped",
    features: [
      "Snow theme",
      "Delta format",
      "Images (insert, resize, placeholders)",
      "Semantic HTML output",
      "Proven LiveView integration"
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Quill Test",
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
        native_format: "quill_delta",
        metadata: %{
          "editor" => "Quill",
          "editor_version" => "2.0.3",
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
          |> push_event("download-pdf", %{base64: pdf_binary, filename: "quill-test.pdf"})

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

              <div id="quill-editor-wrapper" phx-update="ignore">
                <div
                  id="editor-quill"
                  data-initial-content={@editor_html}
                  style="min-height: 400px;"
                >
                </div>
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
                    <div id="quill-header-editor-wrapper" phx-update="ignore">
                      <div id="quill-header-editor" style="min-height:80px;"></div>
                    </div>
                  </div>
                  <div>
                    <div class="label"><span class="label-text text-xs font-medium">Footer Design</span></div>
                    <div id="quill-footer-editor-wrapper" phx-update="ignore">
                      <div id="quill-footer-editor" style="min-height:80px;"></div>
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
      <form id="quill-sync-form" phx-submit="sync_content" class="hidden">
        <input type="hidden" name="editor_html" id="quill-sync-html" value="" />
        <input type="hidden" name="editor_native" id="quill-sync-native" value="" />
        <button type="submit" id="quill-sync-submit">sync</button>
      </form>

      <form id="quill-pdf-form" phx-submit="generate_pdf_with_content" class="hidden">
        <input type="hidden" name="editor_html" id="quill-pdf-html" value="" />
        <input type="hidden" name="header_html" id="quill-pdf-header" value="" />
        <input type="hidden" name="footer_html" id="quill-pdf-footer" value="" />
        <button type="submit" id="quill-pdf-submit">pdf</button>
      </form>
    </div>

    <style>
      #quill-header-editor-wrapper .ql-editor,
      #quill-footer-editor-wrapper .ql-editor {
        min-height: 60px;
        max-height: 100px;
        font-size: 12px;
        overflow-y: auto;
      }
      #quill-header-editor-wrapper .ql-toolbar,
      #quill-footer-editor-wrapper .ql-toolbar {
        padding: 4px;
      }
      #quill-header-editor-wrapper .ql-editor img,
      #quill-footer-editor-wrapper .ql-editor img {
        max-height: 50px;
        width: auto;
        float: left;
        margin-right: 8px;
        margin-bottom: 4px;
      }
    </style>

    <%!-- CDN resources --%>
    <div id="quill-cdn-resources" phx-update="ignore">
      <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/quill@2.0.3/dist/quill.snow.css" />
      <script src="https://cdn.jsdelivr.net/npm/quill@2.0.3/dist/quill.js">
      </script>
    </div>

    <%!-- Editor init + event wiring --%>
    <div id="quill-init-script" phx-update="ignore"><script>
      (function() {
        if (window.__documentCreatorQuillInit) return;
        window.__documentCreatorQuillInit = true;

        function initQuill() {
          var container = document.getElementById("editor-quill");
          if (!container) { setTimeout(initQuill, 100); return; }
          if (typeof Quill === "undefined") { setTimeout(initQuill, 100); return; }

          var quill = new Quill("#editor-quill", {
            theme: "snow",
            modules: {
              toolbar: {
                container: [
                  [{ header: [1, 2, 3, false] }],
                  ["bold", "italic", "underline", "strike"],
                  [{ list: "ordered" }, { list: "bullet" }],
                  ["link", "image", "blockquote", "code-block"],
                  ["clean"]
                ],
                handlers: {
                  image: function() {
                    var url = prompt("Enter image URL:");
                    if (url) {
                      var range = quill.getSelection(true);
                      quill.insertEmbed(range.index, "image", url);
                      quill.setSelection(range.index + 1);
                    }
                  }
                }
              }
            }
          });

          // Make images resizable via CSS + mouse drag
          container.addEventListener("click", function(e) {
            if (e.target.tagName === "IMG") {
              // Select image for resize
              var img = e.target;
              if (img._resizeActive) return;
              img._resizeActive = true;
              img.style.outline = "2px solid #6366f1";
              img.style.cursor = "nwse-resize";

              var startW, startX;
              function onMouseDown(ev) {
                startW = img.offsetWidth;
                startX = ev.clientX;
                ev.preventDefault();
                document.addEventListener("mousemove", onMouseMove);
                document.addEventListener("mouseup", onMouseUp);
              }
              function onMouseMove(ev) {
                var newW = Math.max(50, startW + (ev.clientX - startX));
                img.style.width = newW + "px";
                img.style.height = "auto";
              }
              function onMouseUp() {
                document.removeEventListener("mousemove", onMouseMove);
                document.removeEventListener("mouseup", onMouseUp);
                img.setAttribute("width", img.offsetWidth);
              }
              img.addEventListener("mousedown", onMouseDown);

              // Click elsewhere to deselect
              function deselect(ev) {
                if (ev.target !== img) {
                  img.style.outline = "";
                  img.style.cursor = "";
                  img.removeEventListener("mousedown", onMouseDown);
                  img._resizeActive = false;
                  document.removeEventListener("click", deselect);
                }
              }
              setTimeout(function() { document.addEventListener("click", deselect); }, 0);
            }
          });

          // Image placeholder insertion
          window.__quillInsertPlaceholder = function() {
            var name = prompt("Placeholder variable name (e.g. company_logo):");
            if (!name) return;
            name = name.trim().replace(/[^a-zA-Z0-9_]/g, "_");
            if (!name) return;

            var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120">' +
              '<rect width="200" height="120" fill="#f8f9fa" stroke="#6b7280" stroke-width="2" stroke-dasharray="8,4" rx="8"/>' +
              '<text x="100" y="50" text-anchor="middle" fill="#6b7280" font-family="sans-serif" font-size="12" font-weight="600">Image Placeholder</text>' +
              '<text x="100" y="74" text-anchor="middle" fill="#9ca3af" font-family="monospace" font-size="11">{{ ' + name + ' }}</text></svg>';
            var dataUri = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);

            var range = quill.getSelection(true);
            quill.insertEmbed(range.index, "image", dataUri);
            // Set alt text on the inserted image
            setTimeout(function() {
              var imgs = container.querySelectorAll("img[src^='data:image/svg+xml']");
              var lastImg = imgs[imgs.length - 1];
              if (lastImg) {
                lastImg.setAttribute("alt", "{{ " + name + " }}");
                lastImg.setAttribute("title", "Image placeholder: " + name);
              }
            }, 50);
          };

          // Set initial content from data attribute
          var initial = container.getAttribute("data-initial-content");
          if (initial) {
            quill.clipboard.dangerouslyPasteHTML(initial);
          }

          window.__documentCreatorQuillInstance = quill;

          // --- Mini editors for header/footer (lazy init on details open) ---
          var miniToolbar = [
            ["bold", "italic", "underline"],
            [{ align: [] }],
            ["link", "image"],
            ["clean"]
          ];

          var quillDetails = document.getElementById("quill-header-editor-wrapper")?.closest("details");
          if (quillDetails) {
            quillDetails.addEventListener("toggle", function() {
              if (!quillDetails.open || window.__quillHeaderEditor) return;
              var headerQEl = document.getElementById("quill-header-editor");
              if (headerQEl) {
                window.__quillHeaderEditor = new Quill("#quill-header-editor", {
                  theme: "snow",
                  modules: { toolbar: miniToolbar },
                  placeholder: "Design your PDF header..."
                });
              }
              var footerQEl = document.getElementById("quill-footer-editor");
              if (footerQEl) {
                window.__quillFooterEditor = new Quill("#quill-footer-editor", {
                  theme: "snow",
                  modules: { toolbar: miniToolbar },
                  placeholder: "Design your PDF footer..."
                });
              }
            });
          }

          // Handle export JSON request
          window.addEventListener("phx:request-content", function() {
            var html = quill.getSemanticHTML();
            var native = JSON.stringify(quill.getContents());
            document.getElementById("quill-sync-html").value = html;
            document.getElementById("quill-sync-native").value = native;
            document.getElementById("quill-sync-submit").click();
          });

          // Handle PDF generation request
          window.addEventListener("phx:request-content-for-pdf", function() {
            var html = quill.getSemanticHTML();
            document.getElementById("quill-pdf-html").value = html;
            document.getElementById("quill-pdf-header").value = window.__quillHeaderEditor ? window.__quillHeaderEditor.getSemanticHTML() : "";
            document.getElementById("quill-pdf-footer").value = window.__quillFooterEditor ? window.__quillFooterEditor.getSemanticHTML() : "";
            document.getElementById("quill-pdf-submit").click();
          });

          // Handle content reset from server
          window.addEventListener("phx:editor-set-content", function(e) {
            quill.clipboard.dangerouslyPasteHTML(e.detail.html);
          });

          // Handle placeholder insertion from server
          window.addEventListener("phx:insert-placeholder", function() {
            if (window.__quillInsertPlaceholder) window.__quillInsertPlaceholder();
          });
        }

        // Start initialization
        if (document.readyState === "loading") {
          document.addEventListener("DOMContentLoaded", initQuill);
        } else {
          initQuill();
        }

        // Cleanup on LiveView navigation
        window.addEventListener("phx:page-loading-start", function() {
          window.__documentCreatorQuillInit = false;
          window.__documentCreatorQuillInstance = null;
          window.__quillHeaderEditor = null;
          window.__quillFooterEditor = null;
        });
      })();
    </script></div>

    <%!-- Download handler --%>
    <div id="quill-download-script" phx-update="ignore"><script>
      (function() {
        if (window.__documentCreatorDownloadInitQuill) return;
        window.__documentCreatorDownloadInitQuill = true;
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
