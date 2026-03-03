defmodule PhoenixKitDocForge.Web.OverviewLive do
  @moduledoc """
  Overview page for the Document Creator module.

  Shows environment status, comparison of approaches, and a reference
  of all researched open-source tools for document/PDF generation.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Document Creator",
       chromic_available: PhoenixKitDocForge.chromic_pdf_available?(),
       chrome_installed: PhoenixKitDocForge.chrome_installed?(),
       typst_available: PhoenixKitDocForge.typst_available?()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Header --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body items-center text-center">
          <h2 class="card-title text-3xl">Document Creator</h2>
          <p class="text-base-content/70 mt-1">
            PDF generation testing module. Compare 5 approaches side-by-side: ChromicPDF, Typst, PDF (pure Elixir), PrawnEx, and Mudbrick.
          </p>
        </div>
      </div>

      <%!-- Environment Check --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h3 class="card-title text-lg">Environment Check</h3>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mt-3">
            <.env_check label="Chrome/Chromium" available={@chrome_installed} />
            <.env_check label="ChromicPDF Library" available={@chromic_available} />
            <.env_check label="Typst NIF" available={@typst_available} />
          </div>
          <p :if={not @chrome_installed} class="text-sm text-warning mt-3">
            Install Chrome or Chromium to use the ChromicPDF test page.
          </p>
        </div>
      </div>

      <%!-- Comparison Cards --%>
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="card-title text-lg">
              <span class="hero-globe-alt w-5 h-5" /> ChromicPDF
            </h3>
            <p class="text-sm text-base-content/70">HTML + CSS → headless Chrome → PDF</p>
            <div class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between">
                <span class="text-base-content/60">Speed</span>
                <span>~200-500ms per page</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Quality</span>
                <span>Browser rendering</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Dependencies</span>
                <span>Chrome/Chromium</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Best for</span>
                <span>Reusing HTML/CSS</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">PDF/A</span>
                <span class="badge badge-success badge-sm">Yes (Ghostscript)</span>
              </div>
            </div>
            <div class="card-actions mt-4">
              <a href="document-creator/chromic" data-phx-link="redirect" data-phx-link-state="push" class="btn btn-primary btn-sm w-full">
                Test ChromicPDF
              </a>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="card-title text-lg">
              <span class="hero-document-arrow-down w-5 h-5" /> Typst
            </h3>
            <p class="text-sm text-base-content/70">Typst markup → Rust NIF → PDF</p>
            <div class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between">
                <span class="text-base-content/60">Speed</span>
                <span>~5-30ms per page</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Quality</span>
                <span>Professional typesetting</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Dependencies</span>
                <span>Precompiled NIF</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Best for</span>
                <span>High volume, quality</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">PDF/A</span>
                <span class="badge badge-success badge-sm">Yes (native)</span>
              </div>
            </div>
            <div class="card-actions mt-4">
              <a href="document-creator/typst" data-phx-link="redirect" data-phx-link-state="push" class="btn btn-primary btn-sm w-full">
                Test Typst
              </a>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="card-title text-lg">
              <span class="hero-code-bracket w-5 h-5" /> PDF (Pure Elixir)
            </h3>
            <p class="text-sm text-base-content/70">Elixir code → PDF objects → binary</p>
            <div class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between">
                <span class="text-base-content/60">Speed</span>
                <span>Fast (in-process)</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Quality</span>
                <span>Manual positioning</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Dependencies</span>
                <span class="badge badge-success badge-sm">None</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Best for</span>
                <span>Invoices, reports</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Downloads</span>
                <span>222K</span>
              </div>
            </div>
            <div class="card-actions mt-4">
              <a href="document-creator/pdf-elixir" data-phx-link="redirect" data-phx-link-state="push" class="btn btn-primary btn-sm w-full">
                Test PDF
              </a>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="card-title text-lg">
              <span class="hero-table-cells w-5 h-5" /> PrawnEx
            </h3>
            <p class="text-sm text-base-content/70">Prawn-inspired → PDF (tables, charts)</p>
            <div class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between">
                <span class="text-base-content/60">Speed</span>
                <span>Fast (in-process)</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Quality</span>
                <span>Tables + charts</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Dependencies</span>
                <span class="badge badge-success badge-sm">None</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Best for</span>
                <span>Structured docs</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Downloads</span>
                <span class="text-warning">145 (very new)</span>
              </div>
            </div>
            <div class="card-actions mt-4">
              <a href="document-creator/prawn-ex" data-phx-link="redirect" data-phx-link-state="push" class="btn btn-primary btn-sm w-full">
                Test PrawnEx
              </a>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="card-title text-lg">
              <span class="hero-paint-brush w-5 h-5" /> Mudbrick
            </h3>
            <p class="text-sm text-base-content/70">Pure Elixir → PDF 2.0 (OpenType fonts)</p>
            <div class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between">
                <span class="text-base-content/60">Speed</span>
                <span>Fast (in-process)</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Quality</span>
                <span>Best typography</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Dependencies</span>
                <span>3 pure Elixir</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Best for</span>
                <span>Typography, OTF fonts</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Downloads</span>
                <span>2.4K</span>
              </div>
            </div>
            <div class="card-actions mt-4">
              <a href="document-creator/mudbrick" data-phx-link="redirect" data-phx-link-state="push" class="btn btn-primary btn-sm w-full">
                Test Mudbrick
              </a>
            </div>
          </div>
        </div>
      </div>

      <%!-- Tools Reference --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h3 class="card-title text-lg">Open-Source Tools Reference</h3>
          <p class="text-sm text-base-content/60 mb-4">
            All tools researched for document creation and PDF export in Elixir/Phoenix.
          </p>

          <.tool_section title="PDF Generation Libraries">
            <.tool_row
              name="ChromicPDF"
              package="chromic_pdf"
              desc="HTML→PDF via Chrome DevTools protocol. Community standard. PDF/A support."
              status="active"
            />
            <.tool_row
              name="PrawnEx"
              package="prawn_ex"
              desc="Pure Elixir PDF generation inspired by Ruby's Prawn. Tables, charts, images."
              status="new"
            />
            <.tool_row
              name="Mudbrick"
              package="mudbrick"
              desc="PDF 2.0 generator. Pure functional, OpenType font support with kerning/ligatures."
              status="active"
            />
            <.tool_row
              name="pdf"
              package="pdf"
              desc="Pure Elixir PDF generation. Manual coordinate positioning, no layout engine."
              status="maintained"
            />
            <.tool_row
              name="pdf_generator"
              package="pdf_generator"
              desc="wkhtmltopdf wrapper. High download count but engine is deprecated."
              status="legacy"
            />
          </.tool_section>

          <.tool_section title="Typst-Based">
            <.tool_row
              name="typst"
              package="typst"
              desc="Rustler NIF bindings to Typst. EEx-style template formatting. Fast."
              status="active"
            />
            <.tool_row
              name="Imprintor"
              package="imprintor"
              desc="Typst via Rustler NIF. JSON data binding for templates."
              status="active"
            />
            <.tool_row
              name="ExTypst"
              package="ex_typst"
              desc="Earlier Typst bindings. Superseded by the typst package."
              status="legacy"
            />
          </.tool_section>

          <.tool_section title="Template Engines">
            <.tool_row
              name="Solid"
              package="solid"
              desc="Liquid template engine for Elixir. {{ variable }} substitution with filters."
              status="active"
            />
            <.tool_row
              name="Carbone"
              package="n/a"
              desc="Docker service: DOCX/ODT templates + JSON data → PDF/DOCX. Self-hosted free."
              status="active"
            />
            <.tool_row
              name="docxtemplater"
              package="n/a"
              desc="JS library for DOCX template filling. {placeholder} syntax. Paid image module."
              status="active"
            />
          </.tool_section>

          <.tool_section title="External Services">
            <.tool_row
              name="Gotenberg"
              package="gotenberg_elixir"
              desc="Docker API wrapping Chromium + LibreOffice. HTML/DOCX/ODT → PDF."
              status="active"
            />
            <.tool_row
              name="DocuSeal"
              package="n/a"
              desc="Open-source e-signature platform. Self-hosted, AGPL-3.0. REST API."
              status="active"
            />
            <.tool_row
              name="Documenso"
              package="n/a"
              desc="Open-source DocuSign alternative. TypeScript/Next.js. AGPL-3.0."
              status="active"
            />
            <.tool_row
              name="Wraft"
              package="n/a"
              desc="Document lifecycle platform built in Elixir. Template-driven generation."
              status="active"
            />
          </.tool_section>

          <.tool_section title="Rich Text Editors (for future editing)">
            <.tool_row
              name="TipTap"
              package="n/a"
              desc="Headless editor on ProseMirror. 100+ extensions. MIT. Best LiveView integration."
              status="active"
            />
            <.tool_row
              name="CKEditor 5"
              package="ckeditor5_phoenix"
              desc="Feature-rich editor. GPL/commercial dual license. Phoenix package available."
              status="active"
            />
            <.tool_row
              name="Quill.js"
              package="n/a"
              desc="Simpler rich text editor. Good for basic editing, less extensible than TipTap."
              status="maintained"
            />
          </.tool_section>
        </div>
      </div>
    </div>
    """
  end

  # ===========================================================================
  # Components
  # ===========================================================================

  defp env_check(assigns) do
    ~H"""
    <div class="flex items-center gap-3 p-3 rounded-lg bg-base-200">
      <div class={[
        "badge badge-lg",
        if(@available, do: "badge-success", else: "badge-error")
      ]}>
        {if @available, do: "OK", else: "Missing"}
      </div>
      <span class="text-sm font-medium">{@label}</span>
    </div>
    """
  end

  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp tool_section(assigns) do
    ~H"""
    <div class="mb-4">
      <h4 class="font-semibold text-sm text-base-content/80 mb-2 border-b border-base-200 pb-1">
        {@title}
      </h4>
      <div class="space-y-1">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:package, :string, required: true)
  attr(:desc, :string, required: true)
  attr(:status, :string, required: true)

  defp tool_row(assigns) do
    ~H"""
    <div class="flex items-start gap-3 py-2 px-2 rounded hover:bg-base-200 transition-colors">
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <span class="font-medium text-sm">{@name}</span>
          <code :if={@package != "n/a"} class="text-xs bg-base-200 px-1.5 py-0.5 rounded">
            {@package}
          </code>
          <span class={[
            "badge badge-xs",
            status_class(@status)
          ]}>
            {@status}
          </span>
        </div>
        <p class="text-xs text-base-content/60 mt-0.5">{@desc}</p>
      </div>
    </div>
    """
  end

  defp status_class("active"), do: "badge-success"
  defp status_class("new"), do: "badge-info"
  defp status_class("maintained"), do: "badge-warning"
  defp status_class("legacy"), do: "badge-error"
  defp status_class(_), do: "badge-ghost"
end
