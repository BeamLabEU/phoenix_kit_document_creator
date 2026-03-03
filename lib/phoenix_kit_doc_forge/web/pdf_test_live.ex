defmodule PhoenixKitDocForge.Web.PdfTestLive do
  @moduledoc """
  Interactive testing page for the `pdf` package (pure Elixir).

  Generates a sample contract PDF using manual coordinate positioning,
  text wrapping, tables, and image support.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "PDF (Pure Elixir) Test",
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
        |> push_event("download-pdf", %{base64: base64, filename: "pdf-elixir-test.pdf"})

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
    Pdf.build([size: :a4, compress: true], fn pdf ->
      pdf
      |> Pdf.set_info(title: "Service Agreement", creator: "Document Creator")
      # Title
      |> Pdf.set_font("Helvetica", size: 22, bold: true)
      |> Pdf.text_at({50, 780}, "Service Agreement")
      # Subtitle
      |> Pdf.set_font("Helvetica", 10)
      |> Pdf.set_fill_color({150, 150, 150})
      |> Pdf.text_at({50, 762}, "Agreement No. SA-2026-0042 — Effective #{assigns.contract_date}")
      |> Pdf.set_fill_color(:black)
      # Horizontal rule
      |> Pdf.set_stroke_color({200, 200, 200})
      |> Pdf.set_line_width(0.5)
      |> Pdf.move_to({50, 752})
      |> Pdf.line_append({545, 752})
      |> Pdf.stroke()
      |> Pdf.set_stroke_color(:black)
      # Parties
      |> Pdf.set_font("Helvetica", size: 8, bold: true)
      |> Pdf.set_fill_color({100, 100, 100})
      |> Pdf.text_at({50, 730}, "PROVIDER")
      |> Pdf.text_at({310, 730}, "CLIENT")
      |> Pdf.set_fill_color(:black)
      |> Pdf.set_font("Helvetica", size: 10, bold: true)
      |> Pdf.text_at({50, 716}, assigns.company)
      |> Pdf.text_at({310, 716}, assigns.client_name)
      |> Pdf.set_font("Helvetica", 9)
      |> Pdf.text_at({50, 703}, "123 Innovation Drive")
      |> Pdf.text_at({50, 691}, "San Francisco, CA 94102")
      |> Pdf.text_at({310, 703}, "456 Business Avenue")
      |> Pdf.text_at({310, 691}, "New York, NY 10001")
      # Section 1
      |> Pdf.set_font("Helvetica", size: 13, bold: true)
      |> Pdf.text_at({50, 660}, "1. Scope of Services")
      |> Pdf.set_font("Helvetica", 10)
      |> Pdf.text_wrap!(
        {50, 640},
        {495, 50},
        "The Provider agrees to deliver the following software development services to the Client, " <>
          "as described in this agreement. All deliverables shall meet the quality standards outlined " <>
          "in Section 3 and shall be completed within the timeline specified in Section 4."
      )
      # Section 2
      |> Pdf.set_font("Helvetica", size: 13, bold: true)
      |> Pdf.text_at({50, 575}, "2. Pricing")
      |> Pdf.set_font("Helvetica", 10)
      # Table
      |> Pdf.table!(
        {50, 555},
        {495, 120},
        [
          ["Service", "Hours", "Rate", "Amount"],
          ["Backend Development", "120", "$150/hr", "$18,000"],
          ["Frontend Development", "80", "$140/hr", "$11,200"],
          ["UI/UX Design", "40", "$130/hr", "$5,200"],
          ["Project Management", "30", "$120/hr", "$3,600"],
          ["Total", "", "", assigns.amount]
        ]
      )
      # Section 3
      |> Pdf.set_font("Helvetica", size: 13, bold: true)
      |> Pdf.text_at({50, 420}, "3. Terms and Conditions")
      |> Pdf.set_font("Helvetica", 10)
      |> Pdf.text_wrap!(
        {50, 400},
        {495, 60},
        "Payment is due within 30 days of invoice date. Late payments are subject to 1.5% monthly interest. " <>
          "Either party may terminate this agreement with 30 days written notice. Work completed prior to " <>
          "termination shall be compensated at the rates specified above. All intellectual property created " <>
          "during this engagement shall be transferred to the Client upon full payment."
      )
      # Signature blocks
      |> Pdf.set_line_width(0.5)
      |> Pdf.move_to({50, 290})
      |> Pdf.line_append({250, 290})
      |> Pdf.stroke()
      |> Pdf.move_to({310, 290})
      |> Pdf.line_append({510, 290})
      |> Pdf.stroke()
      |> Pdf.set_font("Helvetica", 9)
      |> Pdf.set_fill_color({100, 100, 100})
      |> Pdf.text_at({50, 275}, "John Smith, CEO")
      |> Pdf.text_at({50, 263}, assigns.company)
      |> Pdf.text_at({310, 275}, "Jane Doe, VP Operations")
      |> Pdf.text_at({310, 263}, assigns.client_name)
      |> Pdf.export()
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-2xl font-bold">PDF (Pure Elixir) Test</h2>
          <p class="text-sm text-base-content/60">Elixir code → PDF objects → binary (zero deps)</p>
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
          <p class="font-semibold text-sm">About the `pdf` package</p>
          <p class="text-xs mt-1">
            Most mature pure Elixir option (222K downloads). Zero external dependencies.
            Supports text wrapping, tables, PNG + JPEG images. Manual coordinate positioning
            with a GenServer-based API. Great for structured documents like invoices and reports.
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
                  The <code>pdf</code> package builds PDF files natively in Elixir using a GenServer process.
                  Everything is coordinate-based — you position text, draw lines, and place images
                  using <code>{"{x, y}"}</code> point values (72 points = 1 inch, origin at bottom-left).
                </p>

                <div class="bg-base-200 p-3 rounded-lg">
                  <p class="font-semibold text-xs mb-2">Key API Functions</p>
                  <ul class="text-xs space-y-1 font-mono">
                    <li>Pdf.build(opts, fn pdf -> ... end)</li>
                    <li>Pdf.text_at(pdf, {"{x, y}"}, "text")</li>
                    <li>Pdf.text_wrap!(pdf, {"{x, y}"}, {"{w, h}"}, "long text...")</li>
                    <li>Pdf.table!(pdf, {"{x, y}"}, {"{w, h}"}, rows)</li>
                    <li>Pdf.add_image(pdf, {"{x, y}"}, path, opts)</li>
                    <li>Pdf.set_font(pdf, "Helvetica", size: 12, bold: true)</li>
                  </ul>
                </div>

                <div class="grid grid-cols-2 gap-3">
                  <div class="bg-base-200 p-3 rounded-lg">
                    <p class="font-semibold text-xs text-success">Strengths</p>
                    <ul class="text-xs mt-1 space-y-0.5">
                      <li>Zero external dependencies</li>
                      <li>PNG + JPEG image support</li>
                      <li>Built-in text wrapping</li>
                      <li>Table generation</li>
                      <li>222K hex downloads</li>
                    </ul>
                  </div>
                  <div class="bg-base-200 p-3 rounded-lg">
                    <p class="font-semibold text-xs text-error">Limitations</p>
                    <ul class="text-xs mt-1 space-y-0.5">
                      <li>Manual coordinate math</li>
                      <li>No auto-pagination</li>
                      <li>Type 1 fonts only (no OTF)</li>
                      <li>No charts or links</li>
                      <li>No CSS-like layout</li>
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
