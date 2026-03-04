defmodule PhoenixKitDocumentCreator.Web.TestingLive do
  @moduledoc """
  Hidden testing hub for alternative editor evaluations.

  Only registered when `config :phoenix_kit_document_creator, :testing_editors, true`.
  Links to pdfme (JSON template designer) and TipTap (rich text editor).
  """
  use Phoenix.LiveView

  @editors [
    %{
      id: "pdfme",
      name: "pdfme",
      tagline: "Visual PDF template designer — absolute positioning, no Chrome",
      icon: "hero-document",
      features: [
        "JSON templates",
        "Direct PDF generation (pdf-lib)",
        "Absolute positioning",
        "Tables with pagination",
        "Barcodes / QR codes",
        "Headers & footers (staticSchema)"
      ],
      path: "testing/pdfme"
    },
    %{
      id: "tiptap",
      name: "TipTap",
      tagline: "Headless ProseMirror framework — most flexible text editor",
      icon: "hero-cursor-arrow-rays",
      features: [
        "100+ extensions",
        "Template variables",
        "Tables, images, resize",
        "JSON + HTML output",
        "Custom toolbar",
        "MIT license"
      ],
      path: "testing/tiptap"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Testing Editors", editors: @editors)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-4xl px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl">Editor Testing</h2>
          <p class="text-sm text-base-content/60">
            Alternative editors kept for evaluation. These are not part of the main
            document builder — they're here so we can demo them if needed.
          </p>
          <div class="alert alert-info mt-2">
            <span class="hero-information-circle w-5 h-5" />
            <span class="text-sm">
              This page is only visible when <code class="bg-base-200 px-1 rounded">:testing_editors</code>
              config is enabled. All editors load from CDN — no extra dependencies.
            </span>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div :for={editor <- @editors} class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="card-title">
              <span class={"#{editor.icon} w-5 h-5"} /> {editor.name}
            </h3>
            <p class="text-sm text-base-content/70">{editor.tagline}</p>
            <div class="flex flex-wrap gap-1 mt-2">
              <span :for={feat <- editor.features} class="badge badge-sm badge-ghost">{feat}</span>
            </div>
            <div class="card-actions mt-4">
              <a
                href={editor.path}
                class="btn btn-primary btn-sm w-full"
              >
                Open {editor.name}
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
