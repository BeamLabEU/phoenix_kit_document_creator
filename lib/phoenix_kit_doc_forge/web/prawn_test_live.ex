defmodule PhoenixKitDocForge.Web.PrawnTestLive do
  @moduledoc """
  Interactive testing page for PrawnEx (pure Elixir).

  Generates a sample contract PDF with tables and styled text
  using the PrawnEx library inspired by Ruby's Prawn.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "PrawnEx Test",
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
      pdf_binary = generate_contract(socket.assigns)
      elapsed = System.monotonic_time(:millisecond) - start
      base64 = Base.encode64(pdf_binary)

      socket =
        socket
        |> assign(last_generation_ms: elapsed, generating: false)
        |> push_event("download-pdf", %{base64: base64, filename: "prawnex-test.pdf"})

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

  defp generate_contract(assigns) do
    # PrawnEx uses build/2 with a path, but we need binary output
    # Use to_binary/1 for in-memory generation
    doc =
      PrawnEx.Document.new()
      |> PrawnEx.add_page()
      # Title
      |> PrawnEx.set_font("Helvetica", 22)
      |> PrawnEx.text_at({50, 780}, "Service Agreement")
      # Subtitle
      |> PrawnEx.set_font("Helvetica", 10)
      |> PrawnEx.set_non_stroking_gray(0.5)
      |> PrawnEx.text_at(
        {50, 760},
        "Agreement No. SA-2026-0042 — Effective #{assigns.contract_date}"
      )
      |> PrawnEx.set_non_stroking_gray(0.0)
      # Parties
      |> PrawnEx.set_font("Helvetica", 8)
      |> PrawnEx.set_non_stroking_gray(0.4)
      |> PrawnEx.text_at({50, 730}, "PROVIDER")
      |> PrawnEx.text_at({310, 730}, "CLIENT")
      |> PrawnEx.set_non_stroking_gray(0.0)
      |> PrawnEx.set_font("Helvetica", 11)
      |> PrawnEx.text_at({50, 716}, assigns.company)
      |> PrawnEx.text_at({310, 716}, assigns.client_name)
      |> PrawnEx.set_font("Helvetica", 9)
      |> PrawnEx.text_at({50, 703}, "123 Innovation Drive, San Francisco, CA 94102")
      |> PrawnEx.text_at({310, 703}, "456 Business Avenue, New York, NY 10001")
      # Section 1
      |> PrawnEx.set_font("Helvetica", 14)
      |> PrawnEx.text_at({50, 670}, "1. Scope of Services")
      |> PrawnEx.set_font("Helvetica", 10)
      |> PrawnEx.text_box(
        "The Provider agrees to deliver the following software development services to the Client, " <>
          "as described in this agreement. All deliverables shall meet the quality standards outlined " <>
          "in Section 3 and shall be completed within the timeline specified in Section 4.",
        at: {50, 650},
        width: 495
      )
      # Section 2
      |> PrawnEx.set_font("Helvetica", 14)
      |> PrawnEx.text_at({50, 580}, "2. Pricing")
      # Table
      |> PrawnEx.table(
        [
          ["Service", "Hours", "Rate", "Amount"],
          ["Backend Development", "120", "$150/hr", "$18,000"],
          ["Frontend Development", "80", "$140/hr", "$11,200"],
          ["UI/UX Design", "40", "$130/hr", "$5,200"],
          ["Project Management", "30", "$120/hr", "$3,600"],
          ["Total", "", "", assigns.amount]
        ],
        at: {50, 560},
        column_widths: [200, 80, 80, 100],
        row_height: 22,
        header: true,
        border: true,
        font_size: 9
      )
      # Section 3
      |> PrawnEx.set_font("Helvetica", 14)
      |> PrawnEx.text_at({50, 410}, "3. Terms and Conditions")
      |> PrawnEx.set_font("Helvetica", 10)
      |> PrawnEx.text_box(
        "Payment is due within 30 days of invoice date. Late payments are subject to 1.5% monthly interest. " <>
          "Either party may terminate this agreement with 30 days written notice. Work completed prior to " <>
          "termination shall be compensated at the rates specified above.",
        at: {50, 390},
        width: 495
      )
      # Signature lines
      |> PrawnEx.set_font("Helvetica", 9)
      |> PrawnEx.set_non_stroking_gray(0.4)
      |> PrawnEx.text_at({50, 270}, "John Smith, CEO — #{assigns.company}")
      |> PrawnEx.text_at({310, 270}, "Jane Doe, VP — #{assigns.client_name}")
      |> PrawnEx.set_non_stroking_gray(0.0)

    PrawnEx.to_binary(doc)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-2xl font-bold">PrawnEx Test</h2>
          <p class="text-sm text-base-content/60">Elixir (Prawn-inspired) → PDF (zero deps)</p>
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
          <p class="font-semibold text-sm">About PrawnEx</p>
          <p class="text-xs mt-1">
            Brand new (Feb 2026, 0.1.x). Zero dependencies. Inspired by Ruby's Prawn.
            Features tables, bar/line charts, text boxes, JPEG images, headers/footers.
            The most feature-complete pure Elixir option but very early stage.
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
                  PrawnEx is inspired by Ruby's Prawn gem. It uses a functional pipe-based API
                  to build PDF documents. Unlike the <code>pdf</code> package, PrawnEx includes
                  built-in table rendering, chart generation, and text box wrapping.
                </p>

                <div class="bg-base-200 p-3 rounded-lg">
                  <p class="font-semibold text-xs mb-2">Key API Functions</p>
                  <ul class="text-xs space-y-1 font-mono">
                    <li>PrawnEx.build(path, fn doc -> ... end)</li>
                    <li>PrawnEx.text_at(doc, {"{x, y}"}, "text")</li>
                    <li>PrawnEx.text_box(doc, "text", at: ..., width: ...)</li>
                    <li>PrawnEx.table(doc, rows, opts)</li>
                    <li>PrawnEx.bar_chart(doc, data, opts)</li>
                    <li>PrawnEx.image(doc, path, at: ..., width: ...)</li>
                  </ul>
                </div>

                <div class="grid grid-cols-2 gap-3">
                  <div class="bg-base-200 p-3 rounded-lg">
                    <p class="font-semibold text-xs text-success">Strengths</p>
                    <ul class="text-xs mt-1 space-y-0.5">
                      <li>Zero external dependencies</li>
                      <li>Built-in tables with headers</li>
                      <li>Bar and line charts</li>
                      <li>Text box wrapping</li>
                      <li>Header/footer callbacks</li>
                    </ul>
                  </div>
                  <div class="bg-base-200 p-3 rounded-lg">
                    <p class="font-semibold text-xs text-error">Limitations</p>
                    <ul class="text-xs mt-1 space-y-0.5">
                      <li>Very new (0.1.x, Feb 2026)</li>
                      <li>145 hex downloads</li>
                      <li>JPEG only (no PNG)</li>
                      <li>Base PDF fonts only</li>
                      <li>No auto-pagination</li>
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
