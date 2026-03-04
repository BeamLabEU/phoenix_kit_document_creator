defmodule PhoenixKitDocumentCreator.Web.EditorTiptapTestLive do
  @moduledoc """
  Test page for the TipTap WYSIWYG editor.

  Loads TipTap + extensions from CDN (ESM via esm.sh), renders a headless editor
  with a full toolbar (formatting, images, tables, alignment, colors),
  syncs content to `DocumentFormat`, and generates PDFs via ChromicPDF.
  """
  use Phoenix.LiveView

  alias PhoenixKitDocumentCreator.DocumentFormat
  alias PhoenixKitDocumentCreator.Web.EditorPdfHelpers

  @editor_info %{
    name: "TipTap",
    version: "2.11.5",
    license: "MIT",
    bundle: "~150KB (core + extensions)",
    features: [
      "Headless (no UI)",
      "ProseMirror foundation",
      "Images (resize, drag, placeholders)",
      "Tables (insert, merge, resize)",
      "Text alignment & colors",
      "Links, underline, highlights",
      "JSON + HTML output",
      "Template variables via {{ }}"
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "TipTap Test",
       editor_info: @editor_info,
       editor_html: DocumentFormat.sample_html(),
       document_json: nil,
       editor_loaded: false,
       generating: false,
       error: nil,
       last_generation_ms: nil,
       chrome_available:
         PhoenixKitDocumentCreator.chromic_pdf_available?() and
           PhoenixKitDocumentCreator.chrome_installed?()
     )}
  end

  @impl true
  def handle_event("editor_ready", _params, socket) do
    {:noreply, assign(socket, editor_loaded: true)}
  end

  def handle_event("sync_content", %{"editor_html" => html} = params, socket) do
    native_str = Map.get(params, "editor_native", "")
    native = if native_str != "", do: Jason.decode!(native_str), else: nil

    doc =
      DocumentFormat.new(html,
        native: native,
        native_format: "prosemirror_json",
        metadata: %{
          "editor" => "TipTap",
          "editor_version" => "2.11.5",
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
          |> push_event("download-pdf", %{base64: pdf_binary, filename: "tiptap-test.pdf"})

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
            <div class="card-body p-0">
              <div id="tiptap-editor-wrapper" phx-update="ignore">
                <%!-- Toolbar — uses inline SVG icons so it works in any parent app
                     without depending on the parent's Tailwind/heroicons build --%>
                <div id="tiptap-toolbar" class="flex flex-wrap items-center gap-0.5 px-2 py-1.5 border-b border-base-300 bg-base-200/50" style="font-size:13px;">
                  <%!-- Text style --%>
                  <div class="flex gap-0.5 pr-2 border-r border-base-300 mr-1">
                    <button onclick="window.__tte?.chain().focus().toggleBold().run()" class="btn btn-ghost btn-xs" title="Bold"><strong>B</strong></button>
                    <button onclick="window.__tte?.chain().focus().toggleItalic().run()" class="btn btn-ghost btn-xs" title="Italic"><em>I</em></button>
                    <button onclick="window.__tte?.chain().focus().toggleUnderline().run()" class="btn btn-ghost btn-xs" title="Underline"><u>U</u></button>
                    <button onclick="window.__tte?.chain().focus().toggleStrike().run()" class="btn btn-ghost btn-xs" title="Strikethrough"><s>S</s></button>
                    <button onclick="window.__tte?.chain().focus().toggleHighlight().run()" class="btn btn-ghost btn-xs" title="Highlight" style="background:#fef08a;">H</button>
                  </div>

                  <%!-- Headings --%>
                  <div class="flex gap-0.5 pr-2 border-r border-base-300 mr-1">
                    <button onclick="window.__tte?.chain().focus().toggleHeading({level:1}).run()" class="btn btn-ghost btn-xs" title="Heading 1">H1</button>
                    <button onclick="window.__tte?.chain().focus().toggleHeading({level:2}).run()" class="btn btn-ghost btn-xs" title="Heading 2">H2</button>
                    <button onclick="window.__tte?.chain().focus().toggleHeading({level:3}).run()" class="btn btn-ghost btn-xs" title="Heading 3">H3</button>
                    <button onclick="window.__tte?.chain().focus().setParagraph().run()" class="btn btn-ghost btn-xs" title="Paragraph">¶</button>
                  </div>

                  <%!-- Alignment --%>
                  <div class="flex gap-0.5 pr-2 border-r border-base-300 mr-1">
                    <button onclick="window.__tte?.chain().focus().setTextAlign('left').run()" class="btn btn-ghost btn-xs" title="Align left">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" style="width:14px;height:14px;"><path fill-rule="evenodd" d="M2 4.75A.75.75 0 012.75 4h14.5a.75.75 0 010 1.5H2.75A.75.75 0 012 4.75zm0 5A.75.75 0 012.75 9h9.5a.75.75 0 010 1.5h-9.5A.75.75 0 012 9.75zm0 5a.75.75 0 01.75-.75h14.5a.75.75 0 010 1.5H2.75a.75.75 0 01-.75-.75z" clip-rule="evenodd" /></svg>
                    </button>
                    <button onclick="window.__tte?.chain().focus().setTextAlign('center').run()" class="btn btn-ghost btn-xs" title="Align center">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" style="width:14px;height:14px;"><path fill-rule="evenodd" d="M2 4.75A.75.75 0 012.75 4h14.5a.75.75 0 010 1.5H2.75A.75.75 0 012 4.75zm3 5A.75.75 0 015.75 9h8.5a.75.75 0 010 1.5h-8.5A.75.75 0 015 9.75zm-3 5a.75.75 0 01.75-.75h14.5a.75.75 0 010 1.5H2.75a.75.75 0 01-.75-.75z" clip-rule="evenodd" /></svg>
                    </button>
                    <button onclick="window.__tte?.chain().focus().setTextAlign('right').run()" class="btn btn-ghost btn-xs" title="Align right">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" style="width:14px;height:14px;"><path fill-rule="evenodd" d="M2 4.75A.75.75 0 012.75 4h14.5a.75.75 0 010 1.5H2.75A.75.75 0 012 4.75zm5 5A.75.75 0 017.75 9h9.5a.75.75 0 010 1.5h-9.5A.75.75 0 017 9.75zm-5 5a.75.75 0 01.75-.75h14.5a.75.75 0 010 1.5H2.75a.75.75 0 01-.75-.75z" clip-rule="evenodd" /></svg>
                    </button>
                  </div>

                  <%!-- Lists --%>
                  <div class="flex gap-0.5 pr-2 border-r border-base-300 mr-1">
                    <button onclick="window.__tte?.chain().focus().toggleBulletList().run()" class="btn btn-ghost btn-xs" title="Bullet list">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" style="width:14px;height:14px;"><path fill-rule="evenodd" d="M2.5 4a1.5 1.5 0 100 3 1.5 1.5 0 000-3zm4.75.75a.75.75 0 000 1.5h10a.75.75 0 000-1.5h-10zm0 5a.75.75 0 000 1.5h10a.75.75 0 000-1.5h-10zm0 5a.75.75 0 000 1.5h10a.75.75 0 000-1.5h-10zM2.5 9a1.5 1.5 0 100 3 1.5 1.5 0 000-3zm0 5a1.5 1.5 0 100 3 1.5 1.5 0 000-3z" clip-rule="evenodd" /></svg>
                    </button>
                    <button onclick="window.__tte?.chain().focus().toggleOrderedList().run()" class="btn btn-ghost btn-xs" title="Ordered list">1.</button>
                    <button onclick="window.__tte?.chain().focus().toggleTaskList().run()" class="btn btn-ghost btn-xs" title="Task list">☑</button>
                    <button onclick="window.__tte?.chain().focus().toggleBlockquote().run()" class="btn btn-ghost btn-xs" title="Blockquote">❝</button>
                  </div>

                  <%!-- Insert --%>
                  <div class="flex gap-0.5 pr-2 border-r border-base-300 mr-1">
                    <button onclick="window.__tiptapInsertImage()" class="btn btn-ghost btn-xs" title="Insert image">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" style="width:14px;height:14px;"><path fill-rule="evenodd" d="M1 5.25A2.25 2.25 0 013.25 3h13.5A2.25 2.25 0 0119 5.25v9.5A2.25 2.25 0 0116.75 17H3.25A2.25 2.25 0 011 14.75v-9.5zm1.5 5.81V14.75c0 .414.336.75.75.75h13.5a.75.75 0 00.75-.75v-2.06l-2.97-2.97a.75.75 0 00-1.06 0l-3 3-1.72-1.72a.75.75 0 00-1.06 0L2.5 11.06zM12 7a1 1 0 11-2 0 1 1 0 012 0z" clip-rule="evenodd" /></svg>
                    </button>
                    <button onclick="window.__tiptapInsertPlaceholder()" class="btn btn-ghost btn-xs" title="Insert image placeholder">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" style="width:14px;height:14px;"><rect x="2" y="4" width="16" height="12" rx="2" stroke-dasharray="3,2"/><text x="10" y="11.5" text-anchor="middle" fill="currentColor" font-size="6" font-family="sans-serif" stroke="none">{ }</text></svg>
                    </button>
                    <button onclick="window.__tiptapInsertLink()" class="btn btn-ghost btn-xs" title="Insert/edit link">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" style="width:14px;height:14px;"><path d="M12.232 4.232a2.5 2.5 0 013.536 3.536l-1.225 1.224a.75.75 0 001.061 1.06l1.224-1.224a4 4 0 00-5.656-5.656l-3 3a4 4 0 00.225 5.865.75.75 0 00.977-1.138 2.5 2.5 0 01-.142-3.667l3-3z" /><path d="M11.603 7.963a.75.75 0 00-.977 1.138 2.5 2.5 0 01.142 3.667l-3 3a2.5 2.5 0 01-3.536-3.536l1.225-1.224a.75.75 0 00-1.061-1.06l-1.224 1.224a4 4 0 105.656 5.656l3-3a4 4 0 00-.225-5.865z" /></svg>
                    </button>
                    <button onclick="window.__tte?.chain().focus().setHorizontalRule().run()" class="btn btn-ghost btn-xs" title="Horizontal rule">―</button>
                  </div>

                  <%!-- Table --%>
                  <div class="flex gap-0.5 pr-2 border-r border-base-300 mr-1">
                    <button onclick="window.__tte?.chain().focus().insertTable({rows:3,cols:3,withHeaderRow:true}).run()" class="btn btn-ghost btn-xs" title="Insert table">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" style="width:14px;height:14px;"><path fill-rule="evenodd" d="M.99 5.24A2.25 2.25 0 013.25 3h13.5A2.25 2.25 0 0119 5.25v9.5A2.25 2.25 0 0116.75 17H3.25A2.25 2.25 0 011 14.75v-9.5zm8.26 4.51V7.5h1.5v2.25H13v1.5h-2.25V13.5h-1.5v-2.25H7v-1.5h2.25z" clip-rule="evenodd" /></svg>
                    </button>
                    <button onclick="window.__tte?.chain().focus().addColumnAfter().run()" class="btn btn-ghost btn-xs text-[10px]" title="Add column">+Col</button>
                    <button onclick="window.__tte?.chain().focus().addRowAfter().run()" class="btn btn-ghost btn-xs text-[10px]" title="Add row">+Row</button>
                    <button onclick="window.__tte?.chain().focus().deleteTable().run()" class="btn btn-ghost btn-xs text-[10px] text-error" title="Delete table">×Tbl</button>
                  </div>

                  <%!-- Undo/Redo --%>
                  <div class="flex gap-0.5">
                    <button onclick="window.__tte?.chain().focus().undo().run()" class="btn btn-ghost btn-xs" title="Undo">↩</button>
                    <button onclick="window.__tte?.chain().focus().redo().run()" class="btn btn-ghost btn-xs" title="Redo">↪</button>
                  </div>
                </div>

                <%!-- Loading indicator --%>
                <div id="tiptap-loading" class="flex items-center justify-center gap-2 py-16 text-base-content/50">
                  <span class="loading loading-spinner loading-sm"></span>
                  <span class="text-sm">Loading TipTap editor from CDN...</span>
                </div>

                <%!-- Editor target --%>
                <div
                  id="editor-tiptap-target"
                  data-initial-content={@editor_html}
                  style="min-height: 500px; display: none;"
                >
                </div>
              </div>

              <div class="flex flex-wrap gap-2 px-4 py-3 border-t border-base-300">
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
                <button class="btn btn-ghost btn-sm" phx-click="reset_content">
                  Reset
                </button>
              </div>

              <%!-- PDF Header/Footer Options --%>
              <details class="px-4 pb-3">
                <summary class="cursor-pointer text-sm font-medium text-base-content/70 hover:text-base-content">
                  PDF Header & Footer Options
                </summary>
                <div class="mt-3 space-y-4">
                  <div>
                    <div class="label"><span class="label-text text-xs font-medium">Header Design</span></div>
                    <div id="tiptap-header-editor-wrapper" phx-update="ignore" class="border border-base-300 rounded-lg overflow-hidden">
                      <div id="tiptap-header-editor" style="min-height:100px;"></div>
                    </div>
                  </div>
                  <div>
                    <div class="label"><span class="label-text text-xs font-medium">Footer Design</span></div>
                    <div id="tiptap-footer-editor-wrapper" phx-update="ignore" class="border border-base-300 rounded-lg overflow-hidden">
                      <div id="tiptap-footer-editor" style="min-height:100px;"></div>
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
      <form id="tiptap-ready-form" phx-submit="editor_ready" class="hidden">
        <button type="submit">ready</button>
      </form>

      <form id="tiptap-sync-form" phx-submit="sync_content" class="hidden">
        <input type="hidden" name="editor_html" id="tiptap-sync-html" value="" />
        <input type="hidden" name="editor_native" id="tiptap-sync-native" value="" />
        <button type="submit" id="tiptap-sync-submit">sync</button>
      </form>

      <form id="tiptap-pdf-form" phx-submit="generate_pdf_with_content" class="hidden">
        <input type="hidden" name="editor_html" id="tiptap-pdf-html" value="" />
        <input type="hidden" name="header_html" id="tiptap-pdf-header" value="" />
        <input type="hidden" name="footer_html" id="tiptap-pdf-footer" value="" />
        <button type="submit" id="tiptap-pdf-submit">pdf</button>
      </form>
    </div>

    <%!-- Editor CSS --%>
    <div id="tiptap-editor-styles" phx-update="ignore"><style>
      /* ProseMirror base */
      .ProseMirror { min-height: 500px; padding: 1.5rem; outline: none; font-family: system-ui, sans-serif; line-height: 1.6; }
      .ProseMirror > *:first-child { margin-top: 0; }

      /* Headings */
      .ProseMirror h1 { font-size: 1.75em; font-weight: 700; margin: 1em 0 0.4em; line-height: 1.2; }
      .ProseMirror h2 { font-size: 1.35em; font-weight: 600; margin: 0.8em 0 0.3em; line-height: 1.3; }
      .ProseMirror h3 { font-size: 1.15em; font-weight: 600; margin: 0.6em 0 0.2em; }
      .ProseMirror p { margin: 0.5em 0; }

      /* Lists */
      .ProseMirror ul { list-style: disc; padding-left: 1.5em; }
      .ProseMirror ol { list-style: decimal; padding-left: 1.5em; }
      .ProseMirror li { margin: 0.2em 0; }
      .ProseMirror ul[data-type="taskList"] { list-style: none; padding-left: 0; }
      .ProseMirror ul[data-type="taskList"] li { display: flex; align-items: flex-start; gap: 0.5em; }
      .ProseMirror ul[data-type="taskList"] li label { margin-top: 0.25em; }

      /* Blockquote */
      .ProseMirror blockquote { border-left: 3px solid oklch(var(--bc) / 0.2); padding-left: 1em; color: oklch(var(--bc) / 0.6); margin: 1em 0; }

      /* Horizontal rule */
      .ProseMirror hr { border: none; border-top: 1px solid oklch(var(--bc) / 0.15); margin: 1.5em 0; }

      /* Images */
      .ProseMirror img { max-width: 100%; height: auto; border-radius: 4px; margin: 0.5em 0; cursor: pointer; }
      .ProseMirror img.ProseMirror-selectednode { outline: 2px solid oklch(var(--p)); border-radius: 4px; }

      /* Image placeholders */
      .ProseMirror img[title^="Image placeholder"] {
        border: 2px dashed oklch(var(--bc) / 0.3);
        border-radius: 8px;
        opacity: 0.85;
      }

      /* Tables */
      .ProseMirror table { border-collapse: collapse; width: 100%; margin: 1em 0; }
      .ProseMirror th, .ProseMirror td { border: 1px solid oklch(var(--bc) / 0.2); padding: 0.5em 0.75em; min-width: 80px; vertical-align: top; }
      .ProseMirror th { background: oklch(var(--b2)); font-weight: 600; }
      .ProseMirror .selectedCell { background: oklch(var(--p) / 0.1); }

      /* Links */
      .ProseMirror a { color: oklch(var(--p)); text-decoration: underline; cursor: pointer; }

      /* Marks */
      .ProseMirror mark { background-color: #fef08a; padding: 0 2px; border-radius: 2px; }
      .ProseMirror u { text-decoration: underline; }

      /* Text alignment */
      .ProseMirror [style*="text-align: center"] { text-align: center; }
      .ProseMirror [style*="text-align: right"] { text-align: right; }
      .ProseMirror [style*="text-align: justify"] { text-align: justify; }

      /* Placeholder */
      .ProseMirror p.is-editor-empty:first-child::before {
        color: oklch(var(--bc) / 0.3);
        content: attr(data-placeholder);
        float: left;
        height: 0;
        pointer-events: none;
      }
      /* Mini editors for header/footer */
      #tiptap-header-editor .ProseMirror,
      #tiptap-footer-editor .ProseMirror {
        min-height: 80px;
        max-height: 120px;
        padding: 0.5rem;
        font-size: 12px;
        line-height: 1.4;
        overflow-y: auto;
      }
      #tiptap-header-editor .ProseMirror img,
      #tiptap-footer-editor .ProseMirror img {
        max-height: 50px;
        width: auto;
        float: left;
        margin-right: 8px;
        margin-bottom: 4px;
      }
      #tiptap-header-editor .ProseMirror p.is-editor-empty:first-child::before,
      #tiptap-footer-editor .ProseMirror p.is-editor-empty:first-child::before {
        color: oklch(var(--bc) / 0.3);
        content: attr(data-placeholder);
        float: left;
        height: 0;
        pointer-events: none;
      }
    </style></div>

    <%!-- Editor init + event wiring (ESM) --%>
    <div id="tiptap-init-script" phx-update="ignore"><script type="module">
      if (!window.__documentCreatorTiptapInit) {
        window.__documentCreatorTiptapInit = true;
        window.__tiptapReady = false;

        console.log("[TipTap] Initializing with extensions...");

        async function initTiptap() {
          var container = document.getElementById("editor-tiptap-target");
          if (!container) {
            setTimeout(initTiptap, 200);
            return;
          }

          var initialHtml = container.getAttribute("data-initial-content") || "<p>Start typing...</p>";
          var loadingEl = document.getElementById("tiptap-loading");

          try {
            console.log("[TipTap] Loading modules from esm.sh...");

            // Load all extensions in parallel. Without ?bundle, esm.sh
            // deduplicates shared dependencies (ProseMirror) automatically.
            var [
              coreM, starterKitM, imageM, tableM, tableRowM, tableHeaderM,
              tableCellM, linkM, underlineM, textAlignM, highlightM,
              textStyleM, colorM, taskListM, taskItemM, placeholderM,
              subscriptM, superscriptM
            ] = await Promise.all([
              import("https://esm.sh/@tiptap/core@2.11.5"),
              import("https://esm.sh/@tiptap/starter-kit@2.11.5"),
              import("https://esm.sh/@tiptap/extension-image@2.11.5"),
              import("https://esm.sh/@tiptap/extension-table@2.11.5"),
              import("https://esm.sh/@tiptap/extension-table-row@2.11.5"),
              import("https://esm.sh/@tiptap/extension-table-header@2.11.5"),
              import("https://esm.sh/@tiptap/extension-table-cell@2.11.5"),
              import("https://esm.sh/@tiptap/extension-link@2.11.5"),
              import("https://esm.sh/@tiptap/extension-underline@2.11.5"),
              import("https://esm.sh/@tiptap/extension-text-align@2.11.5"),
              import("https://esm.sh/@tiptap/extension-highlight@2.11.5"),
              import("https://esm.sh/@tiptap/extension-text-style@2.11.5"),
              import("https://esm.sh/@tiptap/extension-color@2.11.5"),
              import("https://esm.sh/@tiptap/extension-task-list@2.11.5"),
              import("https://esm.sh/@tiptap/extension-task-item@2.11.5"),
              import("https://esm.sh/@tiptap/extension-placeholder@2.11.5"),
              import("https://esm.sh/@tiptap/extension-subscript@2.11.5"),
              import("https://esm.sh/@tiptap/extension-superscript@2.11.5")
            ]);

            console.log("[TipTap] All modules loaded");

            var Editor = coreM.Editor;
            var StarterKit = starterKitM.default || starterKitM.StarterKit;
            var Image = imageM.default || imageM.Image;
            var Table = tableM.default || tableM.Table;
            var TableRow = tableRowM.default || tableRowM.TableRow;
            var TableHeader = tableHeaderM.default || tableHeaderM.TableHeader;
            var TableCell = tableCellM.default || tableCellM.TableCell;
            var Link = linkM.default || linkM.Link;
            var Underline = underlineM.default || underlineM.Underline;
            var TextAlign = textAlignM.default || textAlignM.TextAlign;
            var Highlight = highlightM.default || highlightM.Highlight;
            var TextStyle = textStyleM.default || textStyleM.TextStyle;
            var Color = colorM.default || colorM.Color;
            var TaskList = taskListM.default || taskListM.TaskList;
            var TaskItem = taskItemM.default || taskItemM.TaskItem;
            var Placeholder = placeholderM.default || placeholderM.Placeholder;
            var Subscript = subscriptM.default || subscriptM.Subscript;
            var Superscript = superscriptM.default || superscriptM.Superscript;

            // Show editor, hide loading
            container.style.display = "";
            if (loadingEl) loadingEl.style.display = "none";

            // Extend Image to persist width/height attributes
            var ResizableImage = Image.extend({
              addAttributes: function() {
                return {
                  ...this.parent(),
                  width: { default: null, renderHTML: function(a) { return a.width ? { width: a.width } : {}; }, parseHTML: function(el) { return el.getAttribute("width"); } },
                  height: { default: null, renderHTML: function(a) { return a.height ? { height: a.height } : {}; }, parseHTML: function(el) { return el.getAttribute("height"); } }
                };
              }
            });

            var editor = new Editor({
              element: container,
              extensions: [
                StarterKit,
                ResizableImage.configure({ allowBase64: true, inline: false }),
                Table.configure({ resizable: true }),
                TableRow,
                TableHeader,
                TableCell,
                Link.configure({ openOnClick: false, HTMLAttributes: { rel: "noopener noreferrer" } }),
                Underline,
                TextAlign.configure({ types: ["heading", "paragraph"] }),
                Highlight.configure({ multicolor: false }),
                TextStyle,
                Color,
                TaskList,
                TaskItem.configure({ nested: true }),
                Placeholder.configure({ placeholder: "Start typing your document..." }),
                Subscript,
                Superscript
              ],
              content: initialHtml
            });

            // Short alias for toolbar onclick handlers
            window.__tte = editor;
            window.__tiptapEditor = editor;
            window.__tiptapReady = true;
            console.log("[TipTap] Editor ready with all extensions");

            // --- Mini editors for header/footer (lazy init on details open) ---
            function createMiniTiptap(elementId, placeholderText) {
              var el = document.getElementById(elementId);
              if (!el) return null;
              return new Editor({
                element: el,
                extensions: [
                  StarterKit.configure({ heading: { levels: [1, 2, 3] } }),
                  ResizableImage.configure({ allowBase64: true, inline: true }),
                  Link.configure({ openOnClick: false }),
                  Underline,
                  TextAlign.configure({ types: ["heading", "paragraph"] }),
                  TextStyle,
                  Placeholder.configure({ placeholder: placeholderText })
                ],
                content: ""
              });
            }

            var tiptapDetails = document.getElementById("tiptap-header-editor-wrapper")?.closest("details");
            if (tiptapDetails) {
              tiptapDetails.addEventListener("toggle", function() {
                if (!tiptapDetails.open || window.__tiptapHeaderEditor) return;
                window.__tiptapHeaderEditor = createMiniTiptap("tiptap-header-editor", "Design your PDF header — add logo, company name, contact info...");
                window.__tiptapFooterEditor = createMiniTiptap("tiptap-footer-editor", "Design your PDF footer — page numbers are added automatically...");
              });
            }

            // --- Image resize system ---
            // Uses an overlay div OUTSIDE ProseMirror's DOM to avoid conflicts.
            // Click an image → overlay with corner handles appears on top.
            (function() {
              var overlay = null;
              var activeImg = null;
              var editorWrapper = document.getElementById("tiptap-editor-wrapper");

              function removeOverlay() {
                if (overlay) { overlay.remove(); overlay = null; }
                activeImg = null;
              }

              function positionOverlay(img) {
                var wrapRect = editorWrapper.getBoundingClientRect();
                var imgRect = img.getBoundingClientRect();
                overlay.style.left = (imgRect.left - wrapRect.left) + "px";
                overlay.style.top = (imgRect.top - wrapRect.top) + "px";
                overlay.style.width = imgRect.width + "px";
                overlay.style.height = imgRect.height + "px";
              }

              function showOverlay(img) {
                if (activeImg === img && overlay) { positionOverlay(img); return; }
                removeOverlay();
                activeImg = img;

                overlay = document.createElement("div");
                overlay.className = "tiptap-img-overlay";
                overlay.style.cssText = "position:absolute;pointer-events:none;z-index:15;outline:2px solid oklch(var(--p));border-radius:4px;";

                // Corner handles
                var corners = [
                  { cls: "se", css: "bottom:-6px;right:-6px;cursor:nwse-resize;" },
                  { cls: "sw", css: "bottom:-6px;left:-6px;cursor:nesw-resize;" },
                  { cls: "ne", css: "top:-6px;right:-6px;cursor:nesw-resize;" },
                  { cls: "nw", css: "top:-6px;left:-6px;cursor:nwse-resize;" }
                ];
                corners.forEach(function(c) {
                  var h = document.createElement("div");
                  h.dataset.corner = c.cls;
                  h.style.cssText = "position:absolute;width:12px;height:12px;background:oklch(var(--p));border:2px solid white;border-radius:2px;pointer-events:auto;" + c.css;
                  overlay.appendChild(h);
                });

                // Size label
                var info = document.createElement("div");
                info.className = "tiptap-img-overlay-info";
                info.style.cssText = "position:absolute;bottom:-22px;left:50%;transform:translateX(-50%);background:oklch(var(--p));color:white;font-size:10px;padding:1px 6px;border-radius:3px;white-space:nowrap;pointer-events:none;";
                info.textContent = Math.round(img.offsetWidth) + " × " + Math.round(img.offsetHeight);
                overlay.appendChild(info);

                editorWrapper.style.position = "relative";
                editorWrapper.appendChild(overlay);
                positionOverlay(img);

                // Drag logic on handles
                overlay.addEventListener("mousedown", function(e) {
                  var corner = e.target.dataset.corner;
                  if (!corner) return;
                  e.preventDefault();
                  e.stopPropagation();

                  var startX = e.clientX;
                  var startW = img.offsetWidth;
                  var ratio = (img.naturalHeight && img.naturalWidth) ? img.naturalHeight / img.naturalWidth : img.offsetHeight / img.offsetWidth;
                  var isLeft = corner === "sw" || corner === "nw";

                  function onMove(ev) {
                    var dx = ev.clientX - startX;
                    if (isLeft) dx = -dx;
                    var newW = Math.max(50, startW + dx);
                    var newH = Math.round(newW * ratio);
                    img.style.width = newW + "px";
                    img.style.height = newH + "px";
                    positionOverlay(img);
                    info.textContent = Math.round(newW) + " × " + newH;
                  }

                  function onUp() {
                    document.removeEventListener("mousemove", onMove);
                    document.removeEventListener("mouseup", onUp);
                    // Persist into TipTap node attrs
                    try {
                      var pos = editor.view.posAtDOM(img, 0);
                      var node = editor.view.state.doc.nodeAt(pos);
                      if (node) {
                        editor.view.dispatch(
                          editor.view.state.tr.setNodeMarkup(pos, undefined, {
                            ...node.attrs,
                            width: img.offsetWidth,
                            height: img.offsetHeight
                          })
                        );
                      }
                    } catch(err) { console.warn("[TipTap resize] persist failed:", err); }
                  }

                  document.addEventListener("mousemove", onMove);
                  document.addEventListener("mouseup", onUp);
                });
              }

              // Click image → show overlay
              container.addEventListener("click", function(e) {
                if (e.target.tagName === "IMG") {
                  e.preventDefault();
                  showOverlay(e.target);
                }
              });

              // Click outside → remove overlay
              document.addEventListener("mousedown", function(e) {
                if (overlay && !overlay.contains(e.target) && e.target.tagName !== "IMG") {
                  removeOverlay();
                }
              });

              // Reposition on scroll/resize
              var reposition = function() { if (overlay && activeImg) positionOverlay(activeImg); };
              container.addEventListener("scroll", reposition);
              window.addEventListener("resize", reposition);
            })();

            // Signal LiveView
            var readyForm = document.getElementById("tiptap-ready-form");
            if (readyForm) {
              var btn = readyForm.querySelector("button");
              if (btn) btn.click();
            }
          } catch (err) {
            console.error("[TipTap] Failed to load:", err);
            if (loadingEl) {
              loadingEl.innerHTML = '<div class="text-center"><p class="text-error text-sm font-semibold">Failed to load TipTap</p><p class="text-xs text-base-content/50 mt-1">' +
                err.message + '</p></div>';
            }
          }
        }

        // Insert image via URL prompt
        window.__tiptapInsertImage = function() {
          if (!window.__tiptapReady) return;
          var url = prompt("Enter image URL:");
          if (url) {
            window.__tte.chain().focus().setImage({ src: url }).run();
          }
        };

        // Insert/edit link
        window.__tiptapInsertLink = function() {
          if (!window.__tiptapReady) return;
          var prev = window.__tte.getAttributes("link").href || "";
          var url = prompt("Enter link URL:", prev);
          if (url === null) return; // cancelled
          if (url === "") {
            window.__tte.chain().focus().unsetLink().run();
          } else {
            window.__tte.chain().focus().extendMarkRange("link").setLink({ href: url }).run();
          }
        };

        // Insert image placeholder for templates
        window.__tiptapInsertPlaceholder = function() {
          if (!window.__tiptapReady) return;
          var name = prompt("Placeholder variable name (e.g. company_logo):");
          if (!name) return;
          name = name.trim().replace(/[^a-zA-Z0-9_]/g, '_');
          if (!name) return;

          var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120">' +
            '<rect width="200" height="120" fill="#f8f9fa" stroke="#6b7280" stroke-width="2" ' +
            'stroke-dasharray="8,4" rx="8"/>' +
            '<text x="100" y="50" text-anchor="middle" fill="#6b7280" font-family="sans-serif" ' +
            'font-size="12" font-weight="600">Image Placeholder</text>' +
            '<text x="100" y="74" text-anchor="middle" fill="#9ca3af" font-family="monospace" ' +
            'font-size="11">{{ ' + name + ' }}</text></svg>';
          var dataUri = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);

          window.__tte.chain().focus().setImage({
            src: dataUri,
            alt: '{{ ' + name + ' }}',
            title: 'Image placeholder: ' + name
          }).run();
        };

        initTiptap();

        // Handle export JSON request
        window.addEventListener("phx:request-content", function() {
          if (!window.__tiptapReady || !window.__tiptapEditor) return;
          var editor = window.__tiptapEditor;
          document.getElementById("tiptap-sync-html").value = editor.getHTML();
          document.getElementById("tiptap-sync-native").value = JSON.stringify(editor.getJSON());
          document.getElementById("tiptap-sync-submit").click();
        });

        // Handle PDF generation request
        window.addEventListener("phx:request-content-for-pdf", function() {
          if (!window.__tiptapReady || !window.__tiptapEditor) return;
          document.getElementById("tiptap-pdf-html").value = window.__tiptapEditor.getHTML();
          document.getElementById("tiptap-pdf-header").value = window.__tiptapHeaderEditor ? window.__tiptapHeaderEditor.getHTML() : "";
          document.getElementById("tiptap-pdf-footer").value = window.__tiptapFooterEditor ? window.__tiptapFooterEditor.getHTML() : "";
          document.getElementById("tiptap-pdf-submit").click();
        });

        // Handle content reset from server
        window.addEventListener("phx:editor-set-content", function(e) {
          if (!window.__tiptapReady || !window.__tiptapEditor) return;
          window.__tiptapEditor.commands.setContent(e.detail.html);
        });

        // Cleanup on LiveView navigation
        window.addEventListener("phx:page-loading-start", function() {
          if (window.__tiptapEditor) {
            window.__tiptapEditor.destroy();
            window.__tiptapEditor = null;
            window.__tte = null;
          }
          if (window.__tiptapHeaderEditor) { window.__tiptapHeaderEditor.destroy(); window.__tiptapHeaderEditor = null; }
          if (window.__tiptapFooterEditor) { window.__tiptapFooterEditor.destroy(); window.__tiptapFooterEditor = null; }
          window.__documentCreatorTiptapInit = false;
          window.__tiptapReady = false;
        });
      }
    </script></div>

    <%!-- Download handler --%>
    <div id="tiptap-download-script" phx-update="ignore"><script>
      (function() {
        if (window.__documentCreatorDownloadInitTiptap) return;
        window.__documentCreatorDownloadInitTiptap = true;
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
