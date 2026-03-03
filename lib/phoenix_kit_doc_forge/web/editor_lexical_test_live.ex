defmodule PhoenixKitDocForge.Web.EditorLexicalTestLive do
  @moduledoc """
  Test page for the Lexical (Meta) WYSIWYG editor.

  Loads Lexical from CDN (ESM build via esm.sh) along with React 18,
  renders the editor with a custom toolbar, syncs content to `DocumentFormat`,
  and generates PDFs via ChromicPDF.
  No hooks — uses hidden form + inline JS for LiveView communication.
  """
  use Phoenix.LiveView

  alias PhoenixKitDocForge.DocumentFormat
  alias PhoenixKitDocForge.Web.EditorPdfHelpers

  @editor_info %{
    name: "Lexical",
    version: "0.26.0",
    license: "MIT",
    bundle: "~60KB + React 18",
    features: [
      "Meta's editor framework",
      "Custom nodes",
      "Images (via DecoratorNode)",
      "Accessibility-first",
      "Lightweight core",
      "Requires React"
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Lexical Test",
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
        native_format: "lexical_state",
        metadata: %{
          "editor" => "Lexical",
          "editor_version" => "0.26.0",
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
          |> push_event("download-pdf", %{base64: pdf_binary, filename: "lexical-test.pdf"})

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

      <%!-- React dependency note --%>
      <div class="alert alert-info">
        <span class="hero-information-circle w-5 h-5" />
        <div>
          <p class="font-semibold">Requires React 18</p>
          <p class="text-sm mt-1">
            Lexical depends on React for its reconciler. This page loads React 18.3.1 (~40KB gzipped)
            alongside Lexical (~60KB). Total bundle is ~100KB gzipped.
          </p>
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

              <div id="lexical-editor-wrapper" phx-update="ignore">
                <%!-- Toolbar --%>
                <div id="lexical-toolbar" class="flex flex-wrap gap-1 p-2 border-b border-base-300">
                  <button id="lexical-btn-bold" class="btn btn-ghost btn-xs">B</button>
                  <button id="lexical-btn-italic" class="btn btn-ghost btn-xs">I</button>
                  <button id="lexical-btn-underline" class="btn btn-ghost btn-xs">U</button>
                  <button id="lexical-btn-h1" class="btn btn-ghost btn-xs">H1</button>
                  <button id="lexical-btn-h2" class="btn btn-ghost btn-xs">H2</button>
                  <button id="lexical-btn-ul" class="btn btn-ghost btn-xs">* List</button>
                  <button id="lexical-btn-ol" class="btn btn-ghost btn-xs">1. List</button>
                  <button id="lexical-btn-image" class="btn btn-ghost btn-xs" title="Insert image">Img</button>
                  <button id="lexical-btn-placeholder" class="btn btn-ghost btn-xs" title="Insert image placeholder">{"{ }"}</button>
                  <button id="lexical-btn-undo" class="btn btn-ghost btn-xs">Undo</button>
                  <button id="lexical-btn-redo" class="btn btn-ghost btn-xs">Redo</button>
                </div>
                <%!-- Editor target --%>
                <div
                  id="editor-lexical-target"
                  contenteditable="true"
                  role="textbox"
                  data-initial-content={@editor_html}
                  style="min-height: 400px; border: 1px solid oklch(var(--bc) / 0.2); border-top: none; padding: 1rem; outline: none;"
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
                    <div id="lexical-header-editor-wrapper" phx-update="ignore">
                      <div
                        id="lexical-header-editor"
                        contenteditable="true"
                        role="textbox"
                        style="min-height:80px;max-height:120px;overflow-y:auto;border:1px solid oklch(var(--bc) / 0.2);border-radius:0.5rem;padding:0.5rem;outline:none;font-size:12px;"
                      ></div>
                    </div>
                  </div>
                  <div>
                    <div class="label"><span class="label-text text-xs font-medium">Footer Design</span></div>
                    <div id="lexical-footer-editor-wrapper" phx-update="ignore">
                      <div
                        id="lexical-footer-editor"
                        contenteditable="true"
                        role="textbox"
                        style="min-height:80px;max-height:120px;overflow-y:auto;border:1px solid oklch(var(--bc) / 0.2);border-radius:0.5rem;padding:0.5rem;outline:none;font-size:12px;"
                      ></div>
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
      <form id="lexical-sync-form" phx-submit="sync_content" class="hidden">
        <input type="hidden" name="editor_html" id="lexical-sync-html" value="" />
        <input type="hidden" name="editor_native" id="lexical-sync-native" value="" />
        <button type="submit" id="lexical-sync-submit">sync</button>
      </form>

      <form id="lexical-pdf-form" phx-submit="generate_pdf_with_content" class="hidden">
        <input type="hidden" name="editor_html" id="lexical-pdf-html" value="" />
        <input type="hidden" name="header_html" id="lexical-pdf-header" value="" />
        <input type="hidden" name="footer_html" id="lexical-pdf-footer" value="" />
        <button type="submit" id="lexical-pdf-submit">pdf</button>
      </form>
    </div>

    <%!-- Lexical editor styles --%>
    <div id="lexical-editor-styles" phx-update="ignore"><style>
      #editor-lexical-target p { margin-bottom: 0.5rem; }
      #editor-lexical-target h1 { font-size: 1.5em; font-weight: bold; margin: 0.5em 0; }
      #editor-lexical-target h2 { font-size: 1.25em; font-weight: bold; margin: 0.5em 0; }
      #editor-lexical-target ul { list-style-type: disc; padding-left: 1.5em; }
      #editor-lexical-target ol { list-style-type: decimal; padding-left: 1.5em; }
      #editor-lexical-target li { margin-bottom: 0.25rem; }
      #editor-lexical-target blockquote { border-left: 4px solid #d1d5db; padding-left: 1em; font-style: italic; color: #6b7280; }
      #editor-lexical-target table { border-collapse: collapse; width: 100%; }
      #editor-lexical-target th, #editor-lexical-target td { border: 1px solid #ddd; padding: 0.5em; }
      #editor-lexical-target img { max-width: 100%; height: auto; border-radius: 4px; margin: 0.5em 0; cursor: pointer; }
      #editor-lexical-target img[title^="Image placeholder"] { border: 2px dashed #9ca3af; border-radius: 8px; opacity: 0.85; }
      #lexical-header-editor img,
      #lexical-footer-editor img { max-height: 50px; width: auto; float: left; margin-right: 8px; margin-bottom: 4px; }
    </style></div>

    <%!-- Editor init + event wiring (ESM) --%>
    <div id="lexical-init-script" phx-update="ignore"><script type="module">
      if (!window.__documentCreatorLexicalInit) {
        window.__documentCreatorLexicalInit = true;
        window.__lexicalReady = false;

        async function initLexical() {
          var container = document.getElementById("editor-lexical-target");
          if (!container) { setTimeout(initLexical, 100); return; }

          var initialHtml = container.getAttribute("data-initial-content") || "<p>Start typing...</p>";
          console.log("[Lexical] Loading modules from esm.sh...");

          try {
            // No ?bundle — let esm.sh deduplicate shared deps (same fix as TipTap)
            var [lexicalModule, richTextModule, htmlModule, historyModule, listModule] = await Promise.all([
              import("https://esm.sh/lexical@0.26.0"),
              import("https://esm.sh/@lexical/rich-text@0.26.0"),
              import("https://esm.sh/@lexical/html@0.26.0"),
              import("https://esm.sh/@lexical/history@0.26.0"),
              import("https://esm.sh/@lexical/list@0.26.0")
            ]);
            console.log("[Lexical] All modules loaded");

            var createEditor = lexicalModule.createEditor;
            var $getRoot = lexicalModule.$getRoot;
            var $getSelection = lexicalModule.$getSelection;
            var $isRangeSelection = lexicalModule.$isRangeSelection;
            var $insertNodes = lexicalModule.$insertNodes;
            var FORMAT_TEXT_COMMAND = lexicalModule.FORMAT_TEXT_COMMAND;
            var UNDO_COMMAND = lexicalModule.UNDO_COMMAND;
            var REDO_COMMAND = lexicalModule.REDO_COMMAND;
            var DecoratorNode = lexicalModule.DecoratorNode;

            var registerRichText = richTextModule.registerRichText;
            var HeadingNode = richTextModule.HeadingNode;
            var $createHeadingNode = richTextModule.$createHeadingNode;

            var $generateHtmlFromNodes = htmlModule.$generateHtmlFromNodes;
            var $generateNodesFromDOM = htmlModule.$generateNodesFromDOM;

            var createEmptyHistoryState = historyModule.createEmptyHistoryState;
            var registerHistory = historyModule.registerHistory;

            var ListNode = listModule.ListNode;
            var ListItemNode = listModule.ListItemNode;
            var registerList = listModule.registerList;
            var INSERT_UNORDERED_LIST_COMMAND = listModule.INSERT_UNORDERED_LIST_COMMAND;
            var INSERT_ORDERED_LIST_COMMAND = listModule.INSERT_ORDERED_LIST_COMMAND;

            // Custom ImageNode — Lexical has no built-in image support
            class ImageNode extends DecoratorNode {
              constructor(src, alt, title, width, height, key) {
                super(key);
                this.__src = src;
                this.__alt = alt || "";
                this.__title = title || "";
                this.__width = width || null;
                this.__height = height || null;
              }
              static getType() { return "image"; }
              static clone(node) {
                return new ImageNode(node.__src, node.__alt, node.__title, node.__width, node.__height, node.__key);
              }
              createDOM() {
                var wrapper = document.createElement("div");
                wrapper.style.display = "inline-block";
                wrapper.style.maxWidth = "100%";
                var img = document.createElement("img");
                img.src = this.__src;
                img.alt = this.__alt;
                if (this.__title) img.title = this.__title;
                if (this.__width) { img.width = this.__width; img.style.width = this.__width + "px"; }
                if (this.__height) { img.height = this.__height; img.style.height = this.__height + "px"; }
                img.style.maxWidth = "100%";
                img.style.height = this.__height ? this.__height + "px" : "auto";
                img.draggable = false;
                wrapper.appendChild(img);
                return wrapper;
              }
              updateDOM() { return false; }
              decorate() { return null; }
              isInline() { return false; }
              static importJSON(json) {
                return new ImageNode(json.src, json.alt, json.title, json.width, json.height);
              }
              exportJSON() {
                return { type: "image", version: 1, src: this.__src, alt: this.__alt, title: this.__title, width: this.__width, height: this.__height };
              }
              exportDOM() {
                var img = document.createElement("img");
                img.src = this.__src;
                img.alt = this.__alt;
                if (this.__title) img.title = this.__title;
                if (this.__width) img.setAttribute("width", String(this.__width));
                if (this.__height) img.setAttribute("height", String(this.__height));
                img.style.maxWidth = "100%";
                return { element: img };
              }
              static importDOM() {
                return {
                  img: function() {
                    return {
                      conversion: function(domNode) {
                        var src = domNode.getAttribute("src");
                        if (!src) return null;
                        var alt = domNode.getAttribute("alt") || "";
                        var title = domNode.getAttribute("title") || "";
                        var w = domNode.getAttribute("width") || (domNode.style && domNode.style.width ? parseInt(domNode.style.width) : null);
                        var h = domNode.getAttribute("height") || (domNode.style && domNode.style.height ? parseInt(domNode.style.height) : null);
                        return { node: new ImageNode(src, alt, title, w ? Number(w) : null, h ? Number(h) : null) };
                      },
                      priority: 0
                    };
                  }
                };
              }
            }

            function $createImageNode(src, alt, title) {
              return new ImageNode(src, alt, title);
            }

            var config = {
              namespace: "DocForgeEditor",
              nodes: [HeadingNode, ListNode, ListItemNode, ImageNode],
              onError: function(error) { console.error("[Lexical]", error); },
              theme: {
                paragraph: "mb-2",
                heading: { h1: "text-2xl font-bold mb-2", h2: "text-xl font-bold mb-2" },
                text: { bold: "font-bold", italic: "italic", underline: "underline" },
                list: { ul: "list-disc pl-6", ol: "list-decimal pl-6", listitem: "mb-1" },
                quote: "border-l-4 border-gray-300 pl-4 italic text-gray-600"
              }
            };

            console.log("[Lexical] Creating editor with ImageNode...");
            var editor = createEditor(config);
            editor.setRootElement(container);
            registerRichText(editor);
            registerHistory(editor, createEmptyHistoryState());
            registerList(editor);

            // Import initial HTML
            editor.update(function() {
              var parser = new DOMParser();
              var dom = parser.parseFromString(initialHtml, "text/html");
              var nodes = $generateNodesFromDOM(editor, dom);
              var root = $getRoot();
              root.clear();
              nodes.forEach(function(node) { root.append(node); });
            });

            console.log("[Lexical] Editor created and content loaded");
            window.__lexicalEditor = editor;

            // Store references for toolbar and content extraction
            window.__lexicalModules = {
              FORMAT_TEXT_COMMAND: FORMAT_TEXT_COMMAND,
              UNDO_COMMAND: UNDO_COMMAND,
              REDO_COMMAND: REDO_COMMAND,
              INSERT_UNORDERED_LIST_COMMAND: INSERT_UNORDERED_LIST_COMMAND,
              INSERT_ORDERED_LIST_COMMAND: INSERT_ORDERED_LIST_COMMAND,
              $getSelection: $getSelection,
              $isRangeSelection: $isRangeSelection,
              $getRoot: $getRoot,
              $insertNodes: $insertNodes,
              $createHeadingNode: $createHeadingNode,
              $createImageNode: $createImageNode,
              $generateHtmlFromNodes: $generateHtmlFromNodes,
              $generateNodesFromDOM: $generateNodesFromDOM
            };

            // Wire toolbar buttons
            document.getElementById("lexical-btn-bold").addEventListener("click", function() {
              editor.dispatchCommand(FORMAT_TEXT_COMMAND, "bold");
            });
            document.getElementById("lexical-btn-italic").addEventListener("click", function() {
              editor.dispatchCommand(FORMAT_TEXT_COMMAND, "italic");
            });
            document.getElementById("lexical-btn-underline").addEventListener("click", function() {
              editor.dispatchCommand(FORMAT_TEXT_COMMAND, "underline");
            });
            document.getElementById("lexical-btn-h1").addEventListener("click", function() {
              editor.update(function() {
                var selection = $getSelection();
                if ($isRangeSelection(selection)) {
                  var anchorNode = selection.anchor.getNode();
                  var element = anchorNode.getTopLevelElementOrThrow();
                  var heading = $createHeadingNode("h1");
                  element.replace(heading);
                  heading.append.apply(heading, element.getChildren());
                }
              });
            });
            document.getElementById("lexical-btn-h2").addEventListener("click", function() {
              editor.update(function() {
                var selection = $getSelection();
                if ($isRangeSelection(selection)) {
                  var anchorNode = selection.anchor.getNode();
                  var element = anchorNode.getTopLevelElementOrThrow();
                  var heading = $createHeadingNode("h2");
                  element.replace(heading);
                  heading.append.apply(heading, element.getChildren());
                }
              });
            });
            document.getElementById("lexical-btn-ul").addEventListener("click", function() {
              editor.dispatchCommand(INSERT_UNORDERED_LIST_COMMAND, undefined);
            });
            document.getElementById("lexical-btn-ol").addEventListener("click", function() {
              editor.dispatchCommand(INSERT_ORDERED_LIST_COMMAND, undefined);
            });
            document.getElementById("lexical-btn-undo").addEventListener("click", function() {
              editor.dispatchCommand(UNDO_COMMAND, undefined);
            });
            document.getElementById("lexical-btn-redo").addEventListener("click", function() {
              editor.dispatchCommand(REDO_COMMAND, undefined);
            });

            // Image insertion using custom ImageNode
            function insertImageIntoLexical(src, alt, title) {
              editor.update(function() {
                var imageNode = $createImageNode(src, alt, title);
                $insertNodes([imageNode]);
              });
            }

            document.getElementById("lexical-btn-image").addEventListener("click", function() {
              var url = prompt("Enter image URL:");
              if (url) {
                insertImageIntoLexical(url, "Image", "");
              }
            });

            document.getElementById("lexical-btn-placeholder").addEventListener("click", function() {
              var name = prompt("Placeholder variable name (e.g. company_logo):");
              if (!name) return;
              name = name.trim().replace(/[^a-zA-Z0-9_]/g, "_");
              if (!name) return;

              var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120">' +
                '<rect width="200" height="120" fill="#f8f9fa" stroke="#6b7280" stroke-width="2" stroke-dasharray="8,4" rx="8"/>' +
                '<text x="100" y="50" text-anchor="middle" fill="#6b7280" font-family="sans-serif" font-size="12" font-weight="600">Image Placeholder</text>' +
                '<text x="100" y="74" text-anchor="middle" fill="#9ca3af" font-family="monospace" font-size="11">{{ ' + name + ' }}</text></svg>';
              var dataUri = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
              insertImageIntoLexical(dataUri, "{{ " + name + " }}", "Image placeholder: " + name);
            });

            // --- Image resize overlay system ---
            // Same approach as TipTap: overlay div outside Lexical's DOM tree
            (function() {
              var overlay = null;
              var activeImg = null;
              var editorWrapper = document.getElementById("lexical-editor-wrapper");

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
                overlay.style.cssText = "position:absolute;pointer-events:none;z-index:15;outline:2px solid oklch(var(--p));border-radius:4px;";

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

                var info = document.createElement("div");
                info.style.cssText = "position:absolute;bottom:-22px;left:50%;transform:translateX(-50%);background:oklch(var(--p));color:white;font-size:10px;padding:1px 6px;border-radius:3px;white-space:nowrap;pointer-events:none;";
                info.textContent = Math.round(img.offsetWidth) + " \u00d7 " + Math.round(img.offsetHeight);
                overlay.appendChild(info);

                editorWrapper.style.position = "relative";
                editorWrapper.appendChild(overlay);
                positionOverlay(img);

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
                    info.textContent = Math.round(newW) + " \u00d7 " + newH;
                  }

                  function onUp() {
                    document.removeEventListener("mousemove", onMove);
                    document.removeEventListener("mouseup", onUp);
                    // Persist dimensions into the Lexical ImageNode
                    var finalW = img.offsetWidth;
                    var finalH = img.offsetHeight;
                    editor.update(function() {
                      var root = $getRoot();
                      // Walk all nodes to find the ImageNode matching this img
                      function findImageNode(node) {
                        if (node.getType && node.getType() === "image" && node.__src === img.src) {
                          return node;
                        }
                        if (node.getChildren) {
                          var children = node.getChildren();
                          for (var i = 0; i < children.length; i++) {
                            var found = findImageNode(children[i]);
                            if (found) return found;
                          }
                        }
                        return null;
                      }
                      var imageNode = findImageNode(root);
                      if (imageNode) {
                        var writable = imageNode.getWritable();
                        writable.__width = finalW;
                        writable.__height = finalH;
                      }
                    });
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

            window.__lexicalReady = true;

            // --- Mini editors for header/footer (lazy init on details open) ---
            function createMiniLexical(containerId) {
              var el = document.getElementById(containerId);
              if (!el) return null;
              var miniConfig = {
                namespace: "MiniEditor-" + containerId,
                nodes: [HeadingNode, ListNode, ListItemNode, ImageNode],
                onError: function(err) { console.error("[Lexical mini]", err); },
                theme: {
                  text: { bold: "font-bold", italic: "italic", underline: "underline" }
                }
              };
              var miniEditor = createEditor(miniConfig);
              miniEditor.setRootElement(el);
              registerRichText(miniEditor);
              registerHistory(miniEditor, createEmptyHistoryState());
              return miniEditor;
            }

            var lexicalDetails = document.getElementById("lexical-header-editor-wrapper")?.closest("details");
            if (lexicalDetails) {
              lexicalDetails.addEventListener("toggle", function() {
                if (!lexicalDetails.open || window.__lexicalHeaderEditor) return;
                window.__lexicalHeaderEditor = createMiniLexical("lexical-header-editor");
                window.__lexicalFooterEditor = createMiniLexical("lexical-footer-editor");
              });
            }

            console.log("[Lexical] Ready with all toolbar buttons wired");
          } catch (err) {
            console.error("[Lexical] Failed to load:", err);
            var container = document.getElementById("editor-lexical-target");
            if (container) {
              container.innerHTML = '<div style="padding:2rem;text-align:center;color:#ef4444;">' +
                '<p style="font-weight:600;">Failed to load Lexical</p>' +
                '<p style="font-size:12px;color:#6b7280;margin-top:4px;">' + err.message + '</p></div>';
            }
          }
        }

        initLexical();

        // Handle export JSON request
        window.addEventListener("phx:request-content", function() {
          if (!window.__lexicalReady || !window.__lexicalEditor) return;
          var editor = window.__lexicalEditor;
          var mods = window.__lexicalModules;
          var html = "";
          editor.getEditorState().read(function() {
            html = mods.$generateHtmlFromNodes(editor);
          });
          var native = JSON.stringify(editor.getEditorState().toJSON());
          document.getElementById("lexical-sync-html").value = html;
          document.getElementById("lexical-sync-native").value = native;
          document.getElementById("lexical-sync-submit").click();
        });

        // Handle PDF generation request
        window.addEventListener("phx:request-content-for-pdf", function() {
          if (!window.__lexicalReady || !window.__lexicalEditor) return;
          var editor = window.__lexicalEditor;
          var mods = window.__lexicalModules;
          var html = "";
          editor.getEditorState().read(function() {
            html = mods.$generateHtmlFromNodes(editor);
          });
          document.getElementById("lexical-pdf-html").value = html;
          function getMiniLexicalHtml(miniEditor) {
            if (!miniEditor) return "";
            var html = "";
            miniEditor.getEditorState().read(function() {
              html = mods.$generateHtmlFromNodes(miniEditor);
            });
            return html;
          }
          document.getElementById("lexical-pdf-header").value = getMiniLexicalHtml(window.__lexicalHeaderEditor);
          document.getElementById("lexical-pdf-footer").value = getMiniLexicalHtml(window.__lexicalFooterEditor);
          document.getElementById("lexical-pdf-submit").click();
        });

        // Handle content reset from server
        window.addEventListener("phx:editor-set-content", function(e) {
          if (!window.__lexicalReady || !window.__lexicalEditor) return;
          var editor = window.__lexicalEditor;
          var mods = window.__lexicalModules;
          editor.update(function() {
            var parser = new DOMParser();
            var dom = parser.parseFromString(e.detail.html, "text/html");
            var nodes = mods.$generateNodesFromDOM(editor, dom);
            var root = mods.$getRoot();
            root.clear();
            nodes.forEach(function(node) { root.append(node); });
          });
        });

        // Cleanup on LiveView navigation
        window.addEventListener("phx:page-loading-start", function() {
          window.__documentCreatorLexicalInit = false;
          window.__lexicalReady = false;
          window.__lexicalEditor = null;
          window.__lexicalModules = null;
        });
      }
    </script></div>

    <%!-- Download handler --%>
    <div id="lexical-download-script" phx-update="ignore"><script>
      (function() {
        if (window.__documentCreatorDownloadInitLexical) return;
        window.__documentCreatorDownloadInitLexical = true;
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
