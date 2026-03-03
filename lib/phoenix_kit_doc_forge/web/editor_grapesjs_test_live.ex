defmodule PhoenixKitDocForge.Web.EditorGrapesjsTestLive do
  @moduledoc """
  Test page for GrapesJS drag-and-drop page builder.

  Loads GrapesJS from CDN (UMD build), renders a 2-column layout with
  the builder canvas on the left and the standardized JSON output on the right.
  Uses hidden form + inline JS for LiveView communication (no hooks).

  GrapesJS is a page BUILDER, not a text editor. The UX is fundamentally
  different — it provides a canvas for drag-and-drop visual composition with
  a component system, style manager, and layer panel.
  """
  use Phoenix.LiveView

  alias PhoenixKitDocForge.DocumentFormat
  alias PhoenixKitDocForge.Web.EditorPdfHelpers

  @editor_info %{
    name: "GrapesJS",
    version: "0.22.4",
    license: "BSD 3-Clause",
    bundle: "~310KB gzipped",
    features: [
      "Drag-and-drop builder",
      "Component system",
      "Images (drag, resize, placeholders)",
      "Style manager",
      "Document mode"
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "GrapesJS Test",
       editor_info: @editor_info,
       json_output: nil,
       generating_pdf: false,
       error: nil,
       sample_html: DocumentFormat.sample_html()
     )}
  end

  @impl true
  def handle_event("sync_content", %{"html" => html} = params, socket) do
    native_json = Map.get(params, "native")

    native =
      case native_json do
        nil ->
          nil

        "" ->
          nil

        json_str ->
          case Jason.decode(json_str) do
            {:ok, decoded} -> decoded
            _ -> nil
          end
      end

    doc =
      DocumentFormat.new(html,
        native: native,
        native_format: "grapesjs-project"
      )

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
           filename: "grapesjs-test.pdf"
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
    <div class="flex flex-col mx-auto px-4 py-6 gap-6">
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

      <%!-- Page Builder Note --%>
      <div class="alert alert-warning">
        <span class="hero-exclamation-triangle w-5 h-5" />
        <div>
          <p class="font-semibold">GrapesJS is a Page Builder, Not a Text Editor</p>
          <p class="text-sm">
            GrapesJS provides a drag-and-drop canvas with a component system, style manager, and
            layer panel. The editing experience is fundamentally different from traditional WYSIWYG
            editors. It excels at visual layout design, email templates, and page building.
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
            <div id="grapesjs-header-editor-wrapper" phx-update="ignore" style="display:flex;border:1px solid oklch(var(--bc) / 0.2);border-radius:0.5rem;overflow:hidden;">
              <div id="grapesjs-header-editor" style="flex:1;height:150px;"></div>
              <div id="grapesjs-header-blocks" style="width:120px;border-left:1px solid oklch(var(--bc) / 0.15);overflow-y:auto;background:#f8f9fa;"></div>
            </div>
          </div>
          <div>
            <div class="label"><span class="label-text text-xs font-medium">Footer Design</span></div>
            <div id="grapesjs-footer-editor-wrapper" phx-update="ignore" style="display:flex;border:1px solid oklch(var(--bc) / 0.2);border-radius:0.5rem;overflow:hidden;">
              <div id="grapesjs-footer-editor" style="flex:1;height:150px;"></div>
              <div id="grapesjs-footer-blocks" style="width:120px;border-left:1px solid oklch(var(--bc) / 0.15);overflow-y:auto;background:#f8f9fa;"></div>
            </div>
          </div>
          <p class="text-xs text-base-content/50">
            Images float left so text flows beside them. Use a table for multi-column layouts.
          </p>
        </div>
      </details>

      <%!-- Full-width Builder --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body p-0 overflow-hidden">
          <div id="grapesjs-wrapper" phx-update="ignore" style="display:flex;width:100%;">
            <%!-- Editor canvas --%>
            <div
              id="editor-grapesjs"
              data-initial-content={@sample_html}
              style="flex:1;min-height:700px;"
            ></div>
            <%!-- Right panel: document blocks only --%>
            <div id="grapesjs-right-panel" style="width:240px;min-width:240px;border-left:1px solid #ddd;display:flex;flex-direction:column;background:#f5f5f5;">
              <div style="padding:8px 12px;border-bottom:1px solid #ddd;font-size:12px;font-weight:600;color:#555;">
                Document Elements
              </div>
              <div id="grapesjs-blocks-panel" style="flex:1;overflow-y:auto;"></div>
            </div>
          </div>
        </div>
      </div>

      <%!-- JSON Output (collapsible) --%>
      <div class="collapse collapse-arrow bg-base-100 shadow-xl">
        <input type="checkbox" />
        <div class="collapse-title font-medium text-sm">
          Standardized Document Format (JSON)
        </div>
        <div class="collapse-content">
          <div :if={@json_output} class="mockup-code text-xs overflow-auto max-h-[600px]">
            <pre class="px-4"><code>{@json_output}</code></pre>
          </div>
          <div :if={is_nil(@json_output)} class="text-center py-8 text-base-content/40">
            <p>Click "Export JSON" to see the standardized document format</p>
          </div>
        </div>
      </div>
    </div>

    <%!-- Hidden forms for JS -> LiveView communication --%>
    <form id="grapesjs-sync-form" phx-submit="sync_content" class="hidden" phx-update="ignore">
      <input type="hidden" name="html" id="grapesjs-sync-html" value="" />
      <input type="hidden" name="native" id="grapesjs-sync-native" value="" />
      <button type="submit" id="grapesjs-sync-submit">sync</button>
    </form>
    <form id="grapesjs-pdf-form" phx-submit="generate_pdf_with_content" class="hidden" phx-update="ignore">
      <input type="hidden" name="html" id="grapesjs-pdf-html" value="" />
      <input type="hidden" name="header_html" id="grapesjs-pdf-header" value="" />
      <input type="hidden" name="footer_html" id="grapesjs-pdf-footer" value="" />
      <button type="submit" id="grapesjs-pdf-submit">pdf</button>
    </form>

    <%!-- CDN + Init Script --%>
    <div id="grapesjs-cdn-block" phx-update="ignore">
      <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/grapesjs@0.22.4/dist/css/grapes.min.css" />
      <script src="https://cdn.jsdelivr.net/npm/grapesjs@0.22.4/dist/grapes.min.js"></script>
      <style>
        /* Document-editor mode: clean canvas, no builder chrome */
        #editor-grapesjs { border: 1px solid oklch(var(--bc) / 0.2); overflow: hidden; }
        #editor-grapesjs .gjs-cv-canvas { width: 100%; min-height: 650px; }
        #editor-grapesjs .gjs-frame-wrapper { min-height: 650px; }

        /* Hide page-builder UI: toolbar badges, component hover outlines */
        #editor-grapesjs .gjs-pn-panels { display: none !important; }
        #editor-grapesjs .gjs-com-badge { display: none !important; }
        #editor-grapesjs .gjs-com-tl-badge { display: none !important; }
        #editor-grapesjs .gjs-highlighter { display: none !important; }
        #editor-grapesjs .gjs-toolbar { display: none !important; }
        /* Keep .gjs-resizer-c visible so images can be resized */

        /* === Right panel: override ALL GrapesJS dark theme === */
        #grapesjs-right-panel,
        #grapesjs-blocks-panel,
        #grapesjs-blocks-panel .gjs-block-categories,
        #grapesjs-blocks-panel .gjs-block-category {
          background: #f8f9fa !important;
          color: #333 !important;
        }

        /* Category heading (clickable accordion) */
        #grapesjs-blocks-panel .gjs-block-category .gjs-title {
          font-size: 11px; font-weight: 600; text-transform: uppercase;
          letter-spacing: 0.5px; padding: 10px 10px 6px;
          color: #333 !important;
          background: #f0f0f0 !important;
          border: none !important;
          border-bottom: 1px solid #e0e0e0 !important;
          cursor: pointer;
        }
        #grapesjs-blocks-panel .gjs-block-category .gjs-title:hover {
          background: #e8e8e8 !important;
        }
        /* Caret icon in category title */
        #grapesjs-blocks-panel .gjs-block-category .gjs-caret-icon {
          color: #555 !important;
        }

        /* Block items — single column list */
        #grapesjs-blocks-panel .gjs-blocks-cs {
          display: flex; flex-direction: column; gap: 4px; padding: 8px;
          background: #f8f9fa !important;
        }
        #grapesjs-blocks-panel .gjs-block {
          width: 100%; min-height: 42px; padding: 6px 10px;
          display: flex; align-items: center; justify-content: flex-start;
          font-size: 12px; border-radius: 6px; cursor: grab;
          border: 1px solid #e0e0e0; background: white !important;
          color: #1a1a1a !important;
        }
        #grapesjs-blocks-panel .gjs-block:hover {
          border-color: oklch(var(--p)); background: oklch(var(--p) / 0.05) !important;
        }
        #grapesjs-blocks-panel .gjs-block svg { fill: #555; }
        #grapesjs-blocks-panel .gjs-block-label { color: #1a1a1a !important; }

        /* Mini GrapesJS editors — override dark theme */
        #grapesjs-header-editor .gjs-editor,
        #grapesjs-footer-editor .gjs-editor,
        #grapesjs-header-editor .gjs-cv-canvas,
        #grapesjs-footer-editor .gjs-cv-canvas {
          background: #fff !important;
        }
        #grapesjs-header-editor .gjs-cv-canvas,
        #grapesjs-footer-editor .gjs-cv-canvas {
          width: 100% !important;
        }
        #grapesjs-header-editor .gjs-pn-panels,
        #grapesjs-footer-editor .gjs-pn-panels,
        #grapesjs-header-editor .gjs-com-badge,
        #grapesjs-footer-editor .gjs-com-badge,
        #grapesjs-header-editor .gjs-toolbar,
        #grapesjs-footer-editor .gjs-toolbar {
          display: none !important;
        }
        /* Mini blocks panels — light theme, compact */
        #grapesjs-header-blocks,
        #grapesjs-footer-blocks {
          background: #f8f9fa !important;
        }
        #grapesjs-header-blocks .gjs-blocks-cs,
        #grapesjs-footer-blocks .gjs-blocks-cs {
          display: flex; flex-direction: column; gap: 3px; padding: 6px;
        }
        #grapesjs-header-blocks .gjs-block,
        #grapesjs-footer-blocks .gjs-block {
          width: 100% !important; padding: 6px 8px !important;
          border: 1px solid #e0e0e0 !important; border-radius: 4px !important;
          background: #fff !important; cursor: grab; text-align: center;
          font-size: 10px !important; min-height: 0 !important;
        }
        #grapesjs-header-blocks .gjs-block:hover,
        #grapesjs-footer-blocks .gjs-block:hover {
          border-color: oklch(var(--p)) !important;
          background: oklch(var(--p) / 0.05) !important;
        }
        #grapesjs-header-blocks .gjs-block svg,
        #grapesjs-footer-blocks .gjs-block svg { fill: #555; }
        #grapesjs-header-blocks .gjs-block-label,
        #grapesjs-footer-blocks .gjs-block-label {
          color: #1a1a1a !important; font-size: 10px !important;
        }
      </style>
      <script>
        (function() {
          if (window.__documentCreatorGrapesjsInit) return;
          window.__documentCreatorGrapesjsInit = true;

          function initGrapesJS() {
            var container = document.querySelector('#editor-grapesjs');
            if (!container || typeof grapesjs === 'undefined') {
              setTimeout(initGrapesJS, 100);
              return;
            }

            var initialHtml = container.getAttribute('data-initial-content') || '';

            var editor = grapesjs.init({
              container: '#editor-grapesjs',
              height: '700px',
              width: 'auto',
              fromElement: false,
              components: initialHtml,
              storageManager: false,
              // No devices, panels, style/layer/trait managers — document mode
              deviceManager: { devices: [] },
              panels: { defaults: [] },
              blockManager: {
                appendTo: '#grapesjs-blocks-panel'
              },
              // Disable class-based selector manager
              selectorManager: { componentFirst: true },
              // Canvas config — white document background
              canvas: {
                styles: [
                  'https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap'
                ]
              }
            });

            // Inject document-like styles into the canvas iframe
            editor.on('load', function() {
              var frame = editor.Canvas.getFrameEl();
              if (frame && frame.contentDocument) {
                var style = frame.contentDocument.createElement('style');
                style.textContent = [
                  'body { font-family: Inter, -apple-system, sans-serif; font-size: 14px; line-height: 1.7; color: #1a1a1a; padding: 40px 48px; max-width: 800px; margin: 0 auto; }',
                  'h1 { font-size: 28px; font-weight: 700; margin: 0 0 12px 0; line-height: 1.3; }',
                  'h2 { font-size: 20px; font-weight: 600; margin: 24px 0 8px 0; line-height: 1.3; }',
                  'h3 { font-size: 16px; font-weight: 600; margin: 20px 0 6px 0; }',
                  'p { margin: 0 0 12px 0; }',
                  'ul, ol { margin: 0 0 12px 0; padding-left: 24px; }',
                  'li { margin-bottom: 4px; }',
                  'table { width: 100%; border-collapse: collapse; margin: 16px 0; }',
                  'th { background: #f8f9fa; text-align: left; padding: 10px 14px; font-size: 13px; font-weight: 600; border-bottom: 2px solid #e0e0e0; }',
                  'td { padding: 10px 14px; border-bottom: 1px solid #eee; font-size: 13px; }',
                  'blockquote { border-left: 4px solid #d0d0d0; margin: 16px 0; padding: 8px 16px; color: #555; font-style: italic; }',
                  'hr { border: none; border-top: 2px solid #e0e0e0; margin: 24px 0; }',
                  'img { max-width: 100%; height: auto; border-radius: 4px; }',
                  'a { color: #2563eb; text-decoration: underline; }',
                  '/* Subtle selection highlight instead of builder outlines */',
                  '[data-gjs-type].gjs-selected { outline: 2px solid #6366f1 !important; outline-offset: 2px; border-radius: 2px; }',
                  '[data-gjs-type]:hover { outline: 1px dashed #c7c7c7 !important; outline-offset: 1px; }'
                ].join('\\n');
                frame.contentDocument.head.appendChild(style);
              }
            });

            // --- Document element blocks ---
            var bm = editor.BlockManager;

            // Text blocks
            bm.add('heading-1', {
              label: 'Heading 1',
              category: 'Text',
              content: '<h1>Heading</h1>',
              attributes: { title: 'Drag to add a main heading' }
            });
            bm.add('heading-2', {
              label: 'Heading 2',
              category: 'Text',
              content: '<h2>Subheading</h2>',
              attributes: { title: 'Drag to add a subheading' }
            });
            bm.add('heading-3', {
              label: 'Heading 3',
              category: 'Text',
              content: '<h3>Section heading</h3>',
              attributes: { title: 'Drag to add a section heading' }
            });
            bm.add('paragraph', {
              label: 'Paragraph',
              category: 'Text',
              content: '<p>Type your text here. Click to edit.</p>',
              attributes: { title: 'Drag to add a paragraph' }
            });
            bm.add('blockquote', {
              label: 'Quote',
              category: 'Text',
              content: '<blockquote>Quote text goes here.</blockquote>',
              attributes: { title: 'Drag to add a block quote' }
            });
            bm.add('list-ul', {
              label: 'Bullet List',
              category: 'Text',
              content: '<ul><li>First item</li><li>Second item</li><li>Third item</li></ul>',
              attributes: { title: 'Drag to add a bullet list' }
            });
            bm.add('list-ol', {
              label: 'Numbered List',
              category: 'Text',
              content: '<ol><li>First item</li><li>Second item</li><li>Third item</li></ol>',
              attributes: { title: 'Drag to add a numbered list' }
            });

            // Layout blocks
            bm.add('divider', {
              label: 'Divider',
              category: 'Layout',
              content: '<hr />',
              attributes: { title: 'Drag to add a horizontal divider' }
            });
            bm.add('two-columns', {
              label: '2 Columns',
              category: 'Layout',
              content: '<div style="display:flex;gap:24px;margin:16px 0;"><div style="flex:1;"><p>Left column</p></div><div style="flex:1;"><p>Right column</p></div></div>',
              attributes: { title: 'Drag to add a 2-column layout' }
            });
            bm.add('three-columns', {
              label: '3 Columns',
              category: 'Layout',
              content: '<div style="display:flex;gap:24px;margin:16px 0;"><div style="flex:1;"><p>Column 1</p></div><div style="flex:1;"><p>Column 2</p></div><div style="flex:1;"><p>Column 3</p></div></div>',
              attributes: { title: 'Drag to add a 3-column layout' }
            });

            // Media blocks
            bm.add('image', {
              label: 'Image',
              category: 'Media',
              content: { type: 'image', style: { 'max-width': '100%' } },
              attributes: { title: 'Drag to add an image' }
            });
            bm.add('image-placeholder', {
              label: 'Image Placeholder',
              category: 'Media',
              content: {
                type: 'image',
                attributes: {
                  alt: '{{ placeholder_image }}',
                  title: 'Image placeholder: placeholder_image'
                },
                style: {
                  width: '200px',
                  height: '120px',
                  border: '2px dashed #6b7280',
                  'border-radius': '8px',
                  display: 'block',
                  'object-fit': 'contain'
                }
              },
              attributes: { title: 'Drag to add a template image placeholder' }
            });
            bm.add('table-simple', {
              label: 'Table',
              category: 'Media',
              content: '<table><thead><tr><th>Header 1</th><th>Header 2</th><th>Header 3</th></tr></thead><tbody><tr><td>Cell 1</td><td>Cell 2</td><td>Cell 3</td></tr><tr><td>Cell 4</td><td>Cell 5</td><td>Cell 6</td></tr></tbody></table>',
              attributes: { title: 'Drag to add a table' }
            });

            // Template blocks
            bm.add('text-placeholder', {
              label: 'Text Placeholder',
              category: 'Template',
              content: '<p style="color:#6b7280;font-style:italic;">{{ variable_name }}</p>',
              attributes: { title: 'Drag to add a template text variable' }
            });

            window.__grapesjsEditor = editor;

          // --- Mini GrapesJS editors for header/footer ---
          function initMiniGrapesjs(containerId, placeholder) {
            var el = document.getElementById(containerId);
            if (!el) return null;
            var blocksId = containerId.replace('-editor', '-blocks');
            var mini = grapesjs.init({
              container: '#' + containerId,
              height: '150px',
              width: 'auto',
              fromElement: false,
              components: '',
              storageManager: false,
              dragMode: 'absolute',
              deviceManager: { devices: [] },
              panels: { defaults: [] },
              blockManager: { appendTo: '#' + blocksId },
              selectorManager: { componentFirst: true },
              styleManager: { sectors: [] }
            });

            // Add header/footer blocks with absolute positioning
            var bm = mini.BlockManager;
            bm.add('text', {
              label: 'Text',
              category: '',
              content: {
                type: 'text',
                content: 'Edit text',
                style: { position: 'absolute', top: '10px', left: '10px', 'min-width': '80px', padding: '2px 4px' },
                resizable: true, dmode: 'absolute'
              },
              attributes: { title: 'Drag to add text' }
            });
            bm.add('image', {
              label: 'Image',
              category: '',
              content: {
                type: 'image',
                style: { position: 'absolute', top: '10px', left: '10px', 'max-height': '80px', width: 'auto' },
                resizable: true, dmode: 'absolute'
              },
              attributes: { title: 'Drag to add an image' }
            });
            bm.add('two-col', {
              label: '2 Columns',
              category: '',
              content: '<div style="position:absolute;top:10px;left:10px;display:flex;gap:12px;width:80%;">' +
                '<div style="flex:1;"><p>Left</p></div><div style="flex:1;"><p>Right</p></div></div>',
              attributes: { title: 'Drag for side-by-side layout' }
            });
            bm.add('divider', {
              label: 'Divider',
              category: '',
              content: '<hr style="position:absolute;top:60px;left:10px;width:80%;border:none;border-top:1px solid #ddd;margin:0;" />',
              attributes: { title: 'Drag to add a line' }
            });

            mini.on('load', function() {
              // Set wrapper as positioning context for absolute children
              var wrapper = mini.DomComponents.getWrapper();
              wrapper.setStyle({ position: 'relative', width: '100%', height: '100%', overflow: 'hidden' });

              // Override dark theme on the editor wrapper
              var editorEl = el.querySelector('.gjs-editor');
              if (editorEl) editorEl.style.background = '#fff';
              var cvCanvas = el.querySelector('.gjs-cv-canvas');
              if (cvCanvas) { cvCanvas.style.background = '#fff'; cvCanvas.style.width = '100%'; }

              // Inject styles into canvas iframe
              var frame = mini.Canvas.getFrameEl();
              if (frame && frame.contentDocument) {
                var style = frame.contentDocument.createElement('style');
                style.textContent = [
                  'body { font-family: Helvetica, Arial, sans-serif; font-size: 12px; line-height: 1.5; color: #1a1a1a; background: #fff; position: relative; min-height: 100%; padding: 0; margin: 0; }',
                  'p { margin: 0 0 4px 0; }',
                  'img { max-height: 80px; width: auto; border-radius: 2px; }',
                  'table { border-collapse: collapse; }',
                  'th, td { padding: 4px 8px; border: 1px solid #ddd; font-size: 11px; }',
                  'a { color: #2563eb; }',
                  '[data-gjs-type].gjs-selected { outline: 2px solid #6366f1 !important; outline-offset: 1px; }',
                  '[data-gjs-type]:hover { outline: 1px dashed #c7c7c7 !important; }'
                ].join('\n');
                frame.contentDocument.head.appendChild(style);
              }

              // Hide default panels
              var panelsEl = el.querySelector('.gjs-pn-panels');
              if (panelsEl) panelsEl.style.display = 'none';
            });

            return mini;
          }

          var gjsDetails = document.getElementById("grapesjs-header-editor-wrapper")?.closest("details");
          if (gjsDetails) {
            gjsDetails.addEventListener("toggle", function() {
              if (!gjsDetails.open || window.__grapesjsHeaderEditor) return;
              window.__grapesjsHeaderEditor = initMiniGrapesjs('grapesjs-header-editor', 'Design your PDF header...');
              window.__grapesjsFooterEditor = initMiniGrapesjs('grapesjs-footer-editor', 'Design your PDF footer...');
            });
          }

            // Image placeholder insertion via prompt
            window.__grapesjsInsertPlaceholder = function() {
              var name = prompt("Placeholder variable name (e.g. company_logo):");
              if (!name) return;
              name = name.trim().replace(/[^a-zA-Z0-9_]/g, "_");
              if (!name) return;

              var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120">' +
                '<rect width="200" height="120" fill="#f8f9fa" stroke="#6b7280" stroke-width="2" stroke-dasharray="8,4" rx="8"/>' +
                '<text x="100" y="50" text-anchor="middle" fill="#6b7280" font-family="sans-serif" font-size="12" font-weight="600">Image Placeholder</text>' +
                '<text x="100" y="74" text-anchor="middle" fill="#9ca3af" font-family="monospace" font-size="11">{{ ' + name + ' }}</text></svg>';
              var dataUri = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);

              editor.addComponents({
                type: 'image',
                attributes: {
                  src: dataUri,
                  alt: '{{ ' + name + ' }}',
                  title: 'Image placeholder: ' + name
                },
                style: { 'max-width': '200px' }
              });
            };
          }

          // Listen for export JSON request
          window.addEventListener('phx:request-content', function() {
            if (!window.__grapesjsEditor) return;
            var ed = window.__grapesjsEditor;
            var html = ed.getHtml() + '<style>' + ed.getCss() + '</style>';
            var native = JSON.stringify(ed.getProjectData());

            document.getElementById('grapesjs-sync-html').value = html;
            document.getElementById('grapesjs-sync-native').value = native;
            document.getElementById('grapesjs-sync-submit').click();
          });

          // Listen for PDF generation request
          window.addEventListener('phx:request-content-for-pdf', function() {
            if (!window.__grapesjsEditor) return;
            var ed = window.__grapesjsEditor;
            var html = ed.getHtml() + '<style>' + ed.getCss() + '</style>';

            document.getElementById('grapesjs-pdf-html').value = html;
            function getMiniGjsHtml(mini) {
              if (!mini) return '';
              var h = mini.getHtml();
              var c = mini.getCss();
              return c ? h + '<style>' + c + '</style>' : h;
            }
            document.getElementById('grapesjs-pdf-header').value = getMiniGjsHtml(window.__grapesjsHeaderEditor);
            document.getElementById('grapesjs-pdf-footer').value = getMiniGjsHtml(window.__grapesjsFooterEditor);
            document.getElementById('grapesjs-pdf-submit').click();
          });

          // Listen for set content request
          window.addEventListener('phx:editor-set-content', function(e) {
            if (!window.__grapesjsEditor) return;
            window.__grapesjsEditor.setComponents(e.detail.html || '');
          });

          // Listen for placeholder insertion request
          window.addEventListener('phx:insert-placeholder', function() {
            if (window.__grapesjsInsertPlaceholder) window.__grapesjsInsertPlaceholder();
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

          initGrapesJS();
        })();
      </script>
    </div>
    """
  end
end
