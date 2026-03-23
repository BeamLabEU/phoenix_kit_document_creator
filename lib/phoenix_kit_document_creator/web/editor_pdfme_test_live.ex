defmodule PhoenixKitDocumentCreator.Web.EditorPdfmeTestLive do
  @moduledoc """
  Test page for the pdfme template designer.

  Loads @pdfme/ui Designer from CDN, lets users visually build PDF templates
  with absolute-positioned text, images, tables, and barcodes. Generates PDFs
  client-side via @pdfme/generator (no Chrome needed).
  """
  use Phoenix.LiveView

  @editor_info %{
    name: "pdfme",
    version: "5.5.8",
    license: "MIT",
    bundle: "~2MB (Designer + React)",
    features: [
      "Visual template designer",
      "Absolute positioning",
      "Tables with page breaks",
      "Barcodes / QR codes",
      "Direct PDF generation (no Chrome)",
      "Headers & footers (staticSchema)"
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "pdfme Test",
       editor_info: @editor_info,
       template_json: nil,
       generating: false,
       error: nil,
       last_generation_ms: nil
     )}
  end

  @impl true
  def handle_event("save_template", %{"template" => json}, socket) do
    {:noreply, assign(socket, template_json: json)}
  end

  def handle_event("generate_pdf", _params, socket) do
    {:noreply, push_event(socket, "generate-pdf", %{})}
  end

  def handle_event("pdf_generated", %{"elapsed_ms" => ms}, socket) do
    {:noreply, assign(socket, last_generation_ms: ms)}
  end

  def handle_event("pdf_error", %{"error" => reason}, socket) do
    {:noreply, assign(socket, error: "PDF failed: #{reason}")}
  end

  def handle_event("reset_template", _params, socket) do
    {:noreply,
     socket
     |> assign(template_json: nil)
     |> push_event("reset-template", %{})}
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
              <h2 class="card-title text-2xl">{@editor_info.name} Designer Test</h2>
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
          <div class="alert alert-info mt-3">
            <span class="hero-information-circle w-5 h-5" />
            <div>
              <p class="font-semibold text-sm">Different paradigm — no HTML, no Chrome</p>
              <p class="text-xs mt-1">
                pdfme uses absolute-positioned elements on a fixed page canvas.
                PDFs are generated directly via pdf-lib — no headless Chrome needed.
                Templates are JSON, not HTML.
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span>{@error}</span>
      </div>

      <%!-- Designer --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body p-0">
          <div class="flex items-center justify-between px-6 pt-4">
            <h3 class="card-title text-sm">Template Designer</h3>
            <div class="flex gap-2">
              <button class="btn btn-primary btn-sm" phx-click="generate_pdf">
                Generate PDF
              </button>
              <button class="btn btn-outline btn-sm" id="pdfme-save-btn" phx-click="save_template" phx-value-template="">
                Save Template JSON
              </button>
              <button class="btn btn-ghost btn-sm" phx-click="reset_template">
                Reset
              </button>
            </div>
          </div>
          <div id="pdfme-designer-wrapper" phx-update="ignore" style="height:700px;overflow:hidden;">
            <div id="pdfme-designer" style="width:100%;height:100%;"></div>
          </div>
        </div>
      </div>

      <%!-- Template JSON Output --%>
      <div :if={@template_json} class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h3 class="card-title text-sm">Template JSON</h3>
          <div class="bg-base-200 rounded-lg p-3 mt-2 overflow-auto max-h-[400px]">
            <pre class="text-xs font-mono whitespace-pre-wrap">{@template_json}</pre>
          </div>
        </div>
      </div>
    </div>

    <%!-- pdfme CDN --%>
    <div id="pdfme-cdn-block" phx-update="ignore"></div>

    <div id="pdfme-init-script" phx-update="ignore"><script type="module">
      if (!window.__pdfmeInit) {
        window.__pdfmeInit = true;

        async function initPdfme() {
          var container = document.getElementById("pdfme-designer");
          if (!container) { setTimeout(initPdfme, 200); return; }

          try {
            var [uiMod, schemasMod, generatorMod] = await Promise.all([
              import("https://esm.sh/@pdfme/ui@5.5.8"),
              import("https://esm.sh/@pdfme/schemas@5.5.8"),
              import("https://esm.sh/@pdfme/generator@5.5.8")
            ]);

            var Designer = uiMod.Designer;
            var generate = generatorMod.generate;
            var text = schemasMod.text;
            var image = schemasMod.image;
            var table = schemasMod.table;
            var line = schemasMod.line;
            var rectangle = schemasMod.rectangle;
            var ellipse = schemasMod.ellipse;

            // Collect available plugins — some may not exist in all versions
            var plugins = {};
            if (text) plugins.Text = text;
            if (image) plugins.Image = image;
            if (table) plugins.Table = table;
            if (line) plugins.Line = line;
            if (rectangle) plugins.Rectangle = rectangle;
            if (ellipse) plugins.Ellipse = ellipse;

            // Also try barcodes
            try {
              var barcodes = schemasMod.barcodes;
              if (barcodes) {
                Object.keys(barcodes).forEach(function(k) { plugins[k] = barcodes[k]; });
              }
            } catch(e) {}

            // Sample invoice-like template
            var sampleTemplate = {
              basePdf: {
                width: 210,
                height: 297,
                padding: [25, 10, 20, 10],
                staticSchema: [
                  {
                    name: "__page_number",
                    type: "text",
                    position: { x: 175, y: 285 },
                    width: 25,
                    height: 8,
                    readOnly: true,
                    fontSize: 8,
                    alignment: "right",
                    content: "Page {currentPage} of {totalPages}"
                  }
                ]
              },
              schemas: [
                [
                  {
                    name: "company_name",
                    type: "text",
                    position: { x: 14, y: 10 },
                    width: 80,
                    height: 10,
                    fontSize: 18,
                    fontWeight: "bold",
                    content: "Acme Corp"
                  },
                  {
                    name: "company_tagline",
                    type: "text",
                    position: { x: 14, y: 19 },
                    width: 80,
                    height: 6,
                    fontSize: 9,
                    fontColor: "#666666",
                    content: "Quality widgets since 1985"
                  },
                  {
                    name: "invoice_title",
                    type: "text",
                    position: { x: 140, y: 10 },
                    width: 56,
                    height: 12,
                    fontSize: 22,
                    fontWeight: "bold",
                    alignment: "right",
                    content: "INVOICE"
                  },
                  {
                    name: "invoice_number",
                    type: "text",
                    position: { x: 140, y: 22 },
                    width: 56,
                    height: 6,
                    fontSize: 9,
                    alignment: "right",
                    fontColor: "#666666",
                    content: "#INV-2024-001"
                  },
                  {
                    name: "bill_to_label",
                    type: "text",
                    position: { x: 14, y: 40 },
                    width: 30,
                    height: 6,
                    fontSize: 9,
                    fontWeight: "bold",
                    fontColor: "#999999",
                    content: "BILL TO"
                  },
                  {
                    name: "client_name",
                    type: "text",
                    position: { x: 14, y: 46 },
                    width: 80,
                    height: 7,
                    fontSize: 12,
                    content: "Jane Smith"
                  },
                  {
                    name: "client_address",
                    type: "text",
                    position: { x: 14, y: 53 },
                    width: 80,
                    height: 12,
                    fontSize: 9,
                    fontColor: "#444444",
                    lineHeight: 1.4,
                    content: "123 Main Street\nSpringfield, IL 62701"
                  },
                  {
                    name: "date_label",
                    type: "text",
                    position: { x: 140, y: 40 },
                    width: 56,
                    height: 6,
                    fontSize: 9,
                    fontWeight: "bold",
                    fontColor: "#999999",
                    alignment: "right",
                    content: "DATE"
                  },
                  {
                    name: "invoice_date",
                    type: "text",
                    position: { x: 140, y: 46 },
                    width: 56,
                    height: 7,
                    fontSize: 11,
                    alignment: "right",
                    content: "March 3, 2026"
                  }
                ]
              ]
            };

            window.__pdfmeDesigner = new Designer({
              domContainer: container,
              template: sampleTemplate,
              plugins: plugins
            });

            window.__pdfmeGenerate = generate;
            window.__pdfmePlugins = plugins;
            console.log("[pdfme] Designer ready with plugins:", Object.keys(plugins));

          } catch (err) {
            console.error("[pdfme] Failed to load:", err);
            container.innerHTML = '<div style="padding:2rem;text-align:center;color:#ef4444;">' +
              '<p style="font-weight:600;">Failed to load pdfme</p>' +
              '<p style="font-size:12px;color:#6b7280;margin-top:4px;">' + err.message + '</p>' +
              '<p style="font-size:11px;color:#9ca3af;margin-top:8px;">Check browser console for details. ESM imports require a modern browser.</p></div>';
          }
        }

        initPdfme();

        // Handle save template
        window.addEventListener("click", function(e) {
          var btn = e.target.closest("#pdfme-save-btn");
          if (btn && window.__pdfmeDesigner) {
            var template = window.__pdfmeDesigner.getTemplate();
            var json = JSON.stringify(template, null, 2);
            // Update the phx-value-template and re-click to send to server
            btn.setAttribute("phx-value-template", json);
          }
        }, true);

        // Handle PDF generation
        window.addEventListener("phx:generate-pdf", async function() {
          if (!window.__pdfmeDesigner || !window.__pdfmeGenerate) return;
          var start = performance.now();
          try {
            var template = window.__pdfmeDesigner.getTemplate();
            // Build default inputs from template schema field names
            var inputs = {};
            if (template.schemas && template.schemas[0]) {
              template.schemas[0].forEach(function(field) {
                inputs[field.name] = field.content || field.name;
              });
            }
            var pdf = await window.__pdfmeGenerate({
              template: template,
              inputs: [inputs],
              plugins: window.__pdfmePlugins
            });
            var elapsed = Math.round(performance.now() - start);

            // Notify server of timing
            var lv = document.querySelector("[data-phx-main]");
            if (lv && lv.__lv) {
              lv.__lv.pushEvent("pdf_generated", { elapsed_ms: elapsed });
            }

            // Download the PDF
            var blob = new Blob([pdf], { type: "application/pdf" });
            var url = URL.createObjectURL(blob);
            var a = document.createElement("a");
            a.href = url;
            a.download = "pdfme-test.pdf";
            a.style.display = "none";
            document.body.appendChild(a);
            a.click();
            setTimeout(function() { a.remove(); URL.revokeObjectURL(url); }, 100);
          } catch (err) {
            console.error("[pdfme] Generation failed:", err);
            var lv = document.querySelector("[data-phx-main]");
            if (lv && lv.__lv) {
              lv.__lv.pushEvent("pdf_error", { error: err.message });
            }
          }
        });

        // Handle reset
        window.addEventListener("phx:reset-template", function() {
          if (window.__pdfmeDesigner) {
            // Destroy and re-init would be cleanest, but updateTemplate works too
            window.__pdfmeDesigner.updateTemplate({
              basePdf: { width: 210, height: 297, padding: [10, 10, 10, 10] },
              schemas: [[]]
            });
          }
        });

        // Cleanup on navigation
        window.addEventListener("phx:page-loading-start", function() {
          if (window.__pdfmeDesigner) {
            window.__pdfmeDesigner.destroy();
          }
          window.__pdfmeInit = false;
          window.__pdfmeDesigner = null;
          window.__pdfmeGenerate = null;
          window.__pdfmePlugins = null;
        });
      }
    </script></div>

    <%!-- Download handler --%>
    <div id="pdfme-download-script" phx-update="ignore"><script>
      (function() {
        if (window.__pdfmeDownloadInit) return;
        window.__pdfmeDownloadInit = true;
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
