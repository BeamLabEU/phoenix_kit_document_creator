defmodule PhoenixKitDocForge.Web.EditorsOverviewLive do
  @moduledoc """
  Overview page comparing 7 WYSIWYG/document editors for template building.
  """
  use Phoenix.LiveView

  @editors [
    %{
      id: "tiptap",
      name: "TipTap",
      icon: "hero-cursor-arrow-rays",
      tagline: "Headless ProseMirror framework",
      license: "MIT",
      bundle: "~100KB",
      cdn: "ESM",
      toolbar: "Custom (headless)",
      features: [
        "Block-based",
        "100+ extensions",
        "Template variables via Mention",
        "JSON + HTML output"
      ],
      best_for: "Full control, custom UI, template variable insertion",
      path: "editors/tiptap"
    },
    %{
      id: "quill",
      name: "Quill 2.x",
      icon: "hero-pencil",
      tagline: "Simple, proven rich text editor",
      license: "BSD",
      bundle: "~40KB",
      cdn: "UMD",
      toolbar: "Built-in (Snow theme)",
      features: [
        "Lightweight",
        "Proven LiveView integration",
        "Delta + HTML output",
        "Theme support"
      ],
      best_for: "Simple rich text editing with minimal setup",
      path: "editors/quill"
    },
    %{
      id: "ckeditor",
      name: "CKEditor 5",
      icon: "hero-document-text",
      tagline: "Enterprise-grade editor",
      license: "GPL / Commercial",
      bundle: "~300KB",
      cdn: "UMD",
      toolbar: "Built-in (configurable)",
      features: ["Tables", "Track changes (paid)", "Merge fields", "Export to PDF (paid)"],
      best_for: "Enterprise features, compliance, track changes",
      path: "editors/ckeditor"
    },
    %{
      id: "lexical",
      name: "Lexical",
      icon: "hero-code-bracket-square",
      tagline: "Meta's editor framework",
      license: "MIT",
      bundle: "~60KB + React",
      cdn: "ESM",
      toolbar: "Custom (framework)",
      features: ["Lightweight core", "Custom nodes", "Accessibility", "Used by Meta apps"],
      best_for: "Custom editor experiences, React ecosystems",
      path: "editors/lexical"
    },
    %{
      id: "grapesjs",
      name: "GrapesJS",
      icon: "hero-squares-2x2",
      tagline: "Visual drag-and-drop page builder",
      license: "BSD",
      bundle: "~310KB",
      cdn: "UMD",
      toolbar: "Built-in (canvas)",
      features: ["Drag-and-drop", "Component system", "Style manager", "Document mode"],
      best_for: "Visual layout design, email templates, page building",
      path: "editors/grapesjs"
    },
    %{
      id: "jodit",
      name: "Jodit 4.x",
      icon: "hero-bold",
      tagline: "Zero-dependency TypeScript editor",
      license: "MIT",
      bundle: "~100KB",
      cdn: "UMD",
      toolbar: "Built-in (full)",
      features: ["Zero dependencies", "Pure TypeScript", "Source code editing", "File browser"],
      best_for: "Drop-in WYSIWYG with no framework dependency",
      path: "editors/jodit"
    },
    %{
      id: "pdfme",
      name: "pdfme",
      icon: "hero-document",
      tagline: "Visual PDF template designer",
      license: "MIT",
      bundle: "~2MB",
      cdn: "ESM",
      toolbar: "Built-in (Designer)",
      features: [
        "Absolute positioning",
        "Tables with pagination",
        "Direct PDF (no Chrome)",
        "Template variables"
      ],
      best_for: "Structured PDF templates — invoices, labels, reports",
      path: "editors/pdfme"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Editors Overview",
       editors: @editors
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body items-center text-center">
          <h2 class="card-title text-2xl">Document Editor Comparison</h2>
          <p class="text-base-content/70 mt-1 max-w-2xl">
            Evaluate 7 editors for the template system. Each test page loads the editor
            from CDN, lets you edit a sample document, export to the standardized JSON format,
            and generate a PDF.
          </p>
        </div>
      </div>

      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h3 class="card-title text-lg">Standardized Document Format</h3>
          <p class="text-sm text-base-content/60">
            All editors save to a common JSON format with <code class="bg-base-200 px-1 rounded">content_html</code> as
            the universal interchange field. Switch editors anytime — load HTML into the new editor.
            Optional <code class="bg-base-200 px-1 rounded">content_native</code> preserves editor-specific
            format for round-trip fidelity.
          </p>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <div :for={editor <- @editors} class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="card-title text-lg">
              <span class={"#{editor.icon} w-5 h-5"} /> {editor.name}
            </h3>
            <p class="text-sm text-base-content/70">{editor.tagline}</p>

            <div class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between">
                <span class="text-base-content/60">License</span>
                <span>{editor.license}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Bundle</span>
                <span>{editor.bundle}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">CDN Type</span>
                <span class="badge badge-sm badge-outline">{editor.cdn}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Toolbar</span>
                <span class="text-xs">{editor.toolbar}</span>
              </div>
            </div>

            <div class="flex flex-wrap gap-1 mt-3">
              <span :for={feat <- editor.features} class="badge badge-sm badge-ghost">{feat}</span>
            </div>

            <p class="text-xs text-base-content/50 mt-2">
              <strong>Best for:</strong> {editor.best_for}
            </p>

            <div class="card-actions mt-4">
              <a
                href={editor.path}
                data-phx-link="redirect"
                data-phx-link-state="push"
                class="btn btn-primary btn-sm w-full"
              >
                Test {editor.name}
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
