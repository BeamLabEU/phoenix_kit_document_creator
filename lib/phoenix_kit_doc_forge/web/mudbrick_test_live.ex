defmodule PhoenixKitDocForge.Web.MudbrickTestLive do
  @moduledoc """
  Interactive testing page for Mudbrick (pure Elixir, PDF 2.0).

  Generates a sample document using Mudbrick's functional pipeline API
  with OpenType font support and vector drawing.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Mudbrick Test",
       client_name: "Widget Corp International",
       company: "Acme Development LLC",
       contract_date: "March 1, 2026",
       amount: "$38,000",
       last_generation_ms: nil,
       generating: false,
       error: nil
     )}
  end

  @impl true
  def handle_event("update_form", params, socket) do
    {:noreply,
     assign(socket,
       client_name: params["client_name"] || socket.assigns.client_name,
       company: params["company"] || socket.assigns.company,
       contract_date: params["contract_date"] || socket.assigns.contract_date,
       amount: params["amount"] || socket.assigns.amount
     )}
  end

  def handle_event("generate_pdf", _params, socket) do
    socket = assign(socket, generating: true, error: nil)
    start = System.monotonic_time(:millisecond)

    try do
      pdf_iodata = generate_contract(socket.assigns)
      elapsed = System.monotonic_time(:millisecond) - start
      base64 = pdf_iodata |> IO.iodata_to_binary() |> Base.encode64()

      socket =
        socket
        |> assign(last_generation_ms: elapsed, generating: false)
        |> push_event("download-pdf", %{base64: base64, filename: "mudbrick-test.pdf"})

      {:noreply, socket}
    rescue
      e ->
        {:noreply,
         assign(socket,
           generating: false,
           error: "PDF generation failed: #{Exception.message(e)}"
         )}
    end
  end

  @font_path "/System/Library/Fonts/Supplemental/Arial.ttf"

  defp generate_contract(assigns) do
    import Mudbrick, except: [render: 1]

    font_data = File.read!(@font_path)

    # Table layout constants
    row_h = 20
    col = %{service: 55, hours: 270, rate: 350, amount: 460}
    table_top = 555

    new(
      compress: true,
      fonts: %{arial: font_data},
      title: "Service Agreement",
      creators: ["Document Creator"]
    )
    |> page(size: Mudbrick.Page.size(:a4))
    # ── Title ──
    |> text("Service Agreement",
      font_size: 24,
      position: {50, 780}
    )
    |> text(
      "Agreement No. SA-2026-0042",
      font_size: 10,
      position: {50, 755},
      colour: {0.45, 0.45, 0.45}
    )
    |> text(
      "Effective #{assigns.contract_date}",
      font_size: 10,
      position: {250, 755},
      colour: {0.45, 0.45, 0.45}
    )
    # Thick rule under title
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, 743})
      |> line(to: {545, 743}, width: 1.5, colour: {0.2, 0.2, 0.2})
    end)
    # ── Parties ──
    |> text("PROVIDER",
      font_size: 7,
      position: {50, 720},
      colour: {0.45, 0.45, 0.45}
    )
    |> text(assigns.company,
      font_size: 12,
      position: {50, 704}
    )
    |> text("123 Innovation Drive",
      font_size: 9,
      position: {50, 689},
      colour: {0.35, 0.35, 0.35}
    )
    |> text("San Francisco, CA 94102",
      font_size: 9,
      position: {50, 676},
      colour: {0.35, 0.35, 0.35}
    )
    |> text("CLIENT",
      font_size: 7,
      position: {310, 720},
      colour: {0.45, 0.45, 0.45}
    )
    |> text(assigns.client_name,
      font_size: 12,
      position: {310, 704}
    )
    |> text("456 Business Avenue",
      font_size: 9,
      position: {310, 689},
      colour: {0.35, 0.35, 0.35}
    )
    |> text("New York, NY 10001",
      font_size: 9,
      position: {310, 676},
      colour: {0.35, 0.35, 0.35}
    )
    # Thin rule after parties
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, 660})
      |> line(to: {545, 660}, width: 0.5, colour: {0.75, 0.75, 0.75})
    end)
    # ── Section 1: Scope ──
    |> text("1. Scope of Services",
      font_size: 13,
      position: {50, 640}
    )
    |> text(
      "The Provider agrees to deliver software development services to the\nClient as described in this agreement and any attached statements of\nwork. All deliverables shall meet the quality standards outlined in\nSection 3 and shall be completed within the timeline in Section 4.",
      font_size: 10,
      position: {50, 620},
      leading: 14
    )
    # ── Section 2: Pricing ──
    |> text("2. Pricing",
      font_size: 13,
      position: {50, 568}
    )
    # Table header line (thick top border)
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, table_top + 2})
      |> line(to: {545, table_top + 2}, width: 1.0, colour: {0.3, 0.3, 0.3})
    end)
    # Header text (slightly bolder look via darker colour)
    |> text("Service",
      font_size: 9,
      position: {col.service, table_top - 12},
      colour: {0.15, 0.15, 0.15}
    )
    |> text("Hours",
      font_size: 9,
      position: {col.hours, table_top - 12},
      colour: {0.15, 0.15, 0.15}
    )
    |> text("Rate",
      font_size: 9,
      position: {col.rate, table_top - 12},
      colour: {0.15, 0.15, 0.15}
    )
    |> text("Amount",
      font_size: 9,
      position: {col.amount, table_top - 12},
      colour: {0.15, 0.15, 0.15}
    )
    # Header bottom line
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, table_top - row_h})
      |> line(to: {545, table_top - row_h}, width: 0.75, colour: {0.5, 0.5, 0.5})
    end)
    # Row 1: Backend Development
    |> text("Backend Development", font_size: 9, position: {col.service, table_top - row_h - 14})
    |> text("120", font_size: 9, position: {col.hours, table_top - row_h - 14})
    |> text("$150/hr", font_size: 9, position: {col.rate, table_top - row_h - 14})
    |> text("$18,000", font_size: 9, position: {col.amount, table_top - row_h - 14})
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, table_top - row_h * 2})
      |> line(to: {545, table_top - row_h * 2}, width: 0.25, colour: {0.8, 0.8, 0.8})
    end)
    # Row 2: Frontend Development
    |> text("Frontend Development",
      font_size: 9,
      position: {col.service, table_top - row_h * 2 - 14}
    )
    |> text("80", font_size: 9, position: {col.hours, table_top - row_h * 2 - 14})
    |> text("$140/hr", font_size: 9, position: {col.rate, table_top - row_h * 2 - 14})
    |> text("$11,200", font_size: 9, position: {col.amount, table_top - row_h * 2 - 14})
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, table_top - row_h * 3})
      |> line(to: {545, table_top - row_h * 3}, width: 0.25, colour: {0.8, 0.8, 0.8})
    end)
    # Row 3: UI/UX Design
    |> text("UI/UX Design", font_size: 9, position: {col.service, table_top - row_h * 3 - 14})
    |> text("40", font_size: 9, position: {col.hours, table_top - row_h * 3 - 14})
    |> text("$130/hr", font_size: 9, position: {col.rate, table_top - row_h * 3 - 14})
    |> text("$5,200", font_size: 9, position: {col.amount, table_top - row_h * 3 - 14})
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, table_top - row_h * 4})
      |> line(to: {545, table_top - row_h * 4}, width: 0.25, colour: {0.8, 0.8, 0.8})
    end)
    # Row 4: Project Management
    |> text("Project Management",
      font_size: 9,
      position: {col.service, table_top - row_h * 4 - 14}
    )
    |> text("30", font_size: 9, position: {col.hours, table_top - row_h * 4 - 14})
    |> text("$120/hr", font_size: 9, position: {col.rate, table_top - row_h * 4 - 14})
    |> text("$3,600", font_size: 9, position: {col.amount, table_top - row_h * 4 - 14})
    # Total row (thick top border + bold text)
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, table_top - row_h * 5})
      |> line(to: {545, table_top - row_h * 5}, width: 1.5, colour: {0.2, 0.2, 0.2})
    end)
    |> text("Total", font_size: 10, position: {col.service, table_top - row_h * 5 - 14})
    |> text(assigns.amount, font_size: 10, position: {col.amount, table_top - row_h * 5 - 14})
    # Bottom border
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, table_top - row_h * 6})
      |> line(to: {545, table_top - row_h * 6}, width: 0.5, colour: {0.5, 0.5, 0.5})
    end)
    # ── Section 3: Terms ──
    |> text("3. Terms and Conditions",
      font_size: 13,
      position: {50, 410}
    )
    |> text(
      "Payment is due within 30 days of invoice date. Late payments are\nsubject to 1.5% monthly interest. Either party may terminate this\nagreement with 30 days written notice. Work completed prior to\ntermination shall be compensated at the rates specified above.",
      font_size: 10,
      position: {50, 390},
      leading: 14
    )
    # ── Signatures ──
    |> path(fn p ->
      import Mudbrick.Path

      p
      |> move(to: {50, 290})
      |> line(to: {250, 290}, width: 0.5, colour: {0.3, 0.3, 0.3})
      |> move(to: {310, 290})
      |> line(to: {510, 290}, width: 0.5, colour: {0.3, 0.3, 0.3})
    end)
    |> text("John Smith, CEO",
      font_size: 9,
      position: {50, 274},
      colour: {0.4, 0.4, 0.4}
    )
    |> text(assigns.company,
      font_size: 8,
      position: {50, 261},
      colour: {0.5, 0.5, 0.5}
    )
    |> text("Jane Doe, VP Operations",
      font_size: 9,
      position: {310, 274},
      colour: {0.4, 0.4, 0.4}
    )
    |> text(assigns.client_name,
      font_size: 8,
      position: {310, 261},
      colour: {0.5, 0.5, 0.5}
    )
    |> Mudbrick.render()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-2xl font-bold">Mudbrick Test</h2>
          <p class="text-sm text-base-content/60">Pure Elixir → PDF 2.0 (OpenType fonts, vector paths)</p>
        </div>
        <div :if={@last_generation_ms} class="text-right">
          <div class="stat-value text-lg">{@last_generation_ms}ms</div>
          <div class="text-xs text-base-content/60">generation time</div>
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span class="text-sm">{@error}</span>
      </div>

      <%!-- Info --%>
      <div class="alert alert-info">
        <span class="hero-information-circle w-5 h-5" />
        <div>
          <p class="font-semibold text-sm">About Mudbrick</p>
          <p class="text-xs mt-1">
            Pure Elixir PDF 2.0 generator. Unique selling point: OpenType font support with
            automatic kerning and ligatures. Functional pipeline API. No tables or text
            wrapping — everything is manually positioned. Best for typography-heavy documents
            where font quality matters.
          </p>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Form --%>
        <div class="lg:col-span-1">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="card-title text-sm">Contract Variables</h3>

              <div class="form-control mt-2">
                <label class="label"><span class="label-text text-xs">Company</span></label>
                <input
                  type="text"
                  class="input input-bordered input-sm"
                  value={@company}
                  phx-blur="update_form"
                  name="company"
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text text-xs">Client Name</span></label>
                <input
                  type="text"
                  class="input input-bordered input-sm"
                  value={@client_name}
                  phx-blur="update_form"
                  name="client_name"
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text text-xs">Contract Date</span></label>
                <input
                  type="text"
                  class="input input-bordered input-sm"
                  value={@contract_date}
                  phx-blur="update_form"
                  name="contract_date"
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text text-xs">Total Amount</span></label>
                <input
                  type="text"
                  class="input input-bordered input-sm"
                  value={@amount}
                  phx-blur="update_form"
                  name="amount"
                />
              </div>

              <button
                class="btn btn-primary btn-sm mt-4"
                phx-click="generate_pdf"
                disabled={@generating}
              >
                <span :if={@generating} class="loading loading-spinner loading-xs" />
                {if @generating, do: "Generating...", else: "Generate PDF"}
              </button>
            </div>
          </div>
        </div>

        <%!-- Details --%>
        <div class="lg:col-span-2">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="card-title text-sm">How It Works</h3>
              <div class="text-sm space-y-3 mt-2">
                <p>
                  Mudbrick builds PDF 2.0 files directly from Elixir structs. It models the
                  PDF object tree natively — no external tools, no intermediate formats.
                  The "table" you see is hand-drawn with positioned text and vector lines.
                </p>

                <div class="bg-base-200 p-3 rounded-lg">
                  <p class="font-semibold text-xs mb-2">Key API Functions</p>
                  <ul class="text-xs space-y-1 font-mono">
                    <li>Mudbrick.new(fonts: %{"{...}"}, images: %{"{...}"})</li>
                    <li>|> page(size: Mudbrick.Page.size(:a4))</li>
                    <li>|> text("hello", position: {"{x, y}"}, font_size: 12)</li>
                    <li>|> image(:logo, position: ..., scale: ...)</li>
                    <li>|> path(fn p -> p |> move(to: ...) |> line(to: ...) end)</li>
                    <li>|> render()</li>
                  </ul>
                </div>

                <div class="grid grid-cols-2 gap-3">
                  <div class="bg-base-200 p-3 rounded-lg">
                    <p class="font-semibold text-xs text-success">Strengths</p>
                    <ul class="text-xs mt-1 space-y-0.5">
                      <li>OpenType font support</li>
                      <li>Auto kerning + ligatures</li>
                      <li>PDF 2.0 (modern spec)</li>
                      <li>Rich inline text styling</li>
                      <li>Pure Elixir (3 deps)</li>
                    </ul>
                  </div>
                  <div class="bg-base-200 p-3 rounded-lg">
                    <p class="font-semibold text-xs text-error">Limitations</p>
                    <ul class="text-xs mt-1 space-y-0.5">
                      <li>No tables (manual only)</li>
                      <li>No text wrapping</li>
                      <li>JPEG only (no PNG)</li>
                      <li>No auto-pagination</li>
                      <li>2.4K hex downloads</li>
                    </ul>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div id="document-creator-download-script" phx-update="ignore"><script>
      (function() {
        if (window.__documentCreatorDownloadInit) return;
        window.__documentCreatorDownloadInit = true;
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
