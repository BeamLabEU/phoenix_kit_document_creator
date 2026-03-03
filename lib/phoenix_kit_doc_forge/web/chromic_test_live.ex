defmodule PhoenixKitDocForge.Web.ChromicTestLive do
  @moduledoc """
  Interactive testing page for ChromicPDF.

  Enter HTML content, configure paper options, and generate a PDF download.
  Uses `Phoenix.LiveView.send_download/3` for file delivery.
  """
  use Phoenix.LiveView

  @default_html """
  <!DOCTYPE html>
  <html>
  <head>
    <style>
      body { font-family: Helvetica, Arial, sans-serif; font-size: 11pt; line-height: 1.6; color: #1a1a1a; margin: 0; padding: 40px; }
      h1 { font-size: 22pt; color: #1a1a1a; margin-bottom: 4px; }
      h2 { font-size: 14pt; color: #333; margin-top: 24px; margin-bottom: 8px; }
      .subtitle { color: #666; font-size: 10pt; margin-bottom: 24px; }
      .parties { display: flex; gap: 40px; margin: 20px 0; }
      .party { flex: 1; }
      .party-label { font-weight: bold; color: #666; font-size: 9pt; text-transform: uppercase; letter-spacing: 0.5px; }
      table { width: 100%; border-collapse: collapse; margin: 16px 0; }
      th { background: #f5f5f5; text-align: left; padding: 8px 12px; font-size: 10pt; border-bottom: 2px solid #ddd; }
      td { padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 10pt; }
      .total-row td { font-weight: bold; border-top: 2px solid #333; border-bottom: none; }
      .signature-block { margin-top: 60px; display: flex; gap: 60px; }
      .signature { flex: 1; }
      .signature-line { border-bottom: 1px solid #333; height: 40px; margin-bottom: 4px; }
      .signature-name { font-size: 9pt; color: #666; }
      .section { margin-bottom: 16px; }
      .clause { margin-bottom: 8px; }
    </style>
  </head>
  <body>
    <h1>Service Agreement</h1>
    <p class="subtitle">Agreement No. SA-2026-0042 &mdash; Effective February 28, 2026</p>

    <div class="parties">
      <div class="party">
        <p class="party-label">Provider</p>
        <p><strong>Acme Development LLC</strong><br>123 Innovation Drive<br>San Francisco, CA 94102</p>
      </div>
      <div class="party">
        <p class="party-label">Client</p>
        <p><strong>Widget Corp International</strong><br>456 Business Avenue<br>New York, NY 10001</p>
      </div>
    </div>

    <h2>1. Scope of Services</h2>
    <div class="section">
      <p class="clause">The Provider agrees to deliver the following software development services to the Client, as described in this agreement and any attached statements of work.</p>
      <p class="clause">All deliverables shall meet the quality standards outlined in Section 3 and shall be completed within the timeline specified in Section 4.</p>
    </div>

    <h2>2. Pricing</h2>
    <table>
      <thead>
        <tr>
          <th>Service</th>
          <th>Hours</th>
          <th>Rate</th>
          <th style="text-align: right">Amount</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>Backend Development</td>
          <td>120</td>
          <td>$150/hr</td>
          <td style="text-align: right">$18,000</td>
        </tr>
        <tr>
          <td>Frontend Development</td>
          <td>80</td>
          <td>$140/hr</td>
          <td style="text-align: right">$11,200</td>
        </tr>
        <tr>
          <td>UI/UX Design</td>
          <td>40</td>
          <td>$130/hr</td>
          <td style="text-align: right">$5,200</td>
        </tr>
        <tr>
          <td>Project Management</td>
          <td>30</td>
          <td>$120/hr</td>
          <td style="text-align: right">$3,600</td>
        </tr>
        <tr class="total-row">
          <td colspan="3">Total</td>
          <td style="text-align: right">$38,000</td>
        </tr>
      </tbody>
    </table>

    <h2>3. Terms and Conditions</h2>
    <div class="section">
      <p class="clause">Payment is due within 30 days of invoice date. Late payments are subject to 1.5% monthly interest.</p>
      <p class="clause">Either party may terminate this agreement with 30 days written notice. Work completed prior to termination shall be compensated at the rates specified above.</p>
      <p class="clause">All intellectual property created during this engagement shall be transferred to the Client upon full payment.</p>
    </div>

    <div class="signature-block">
      <div class="signature">
        <div class="signature-line"></div>
        <p class="signature-name">John Smith, CEO<br>Acme Development LLC</p>
      </div>
      <div class="signature">
        <div class="signature-line"></div>
        <p class="signature-name">Jane Doe, VP Operations<br>Widget Corp International</p>
      </div>
    </div>
  </body>
  </html>
  """

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "ChromicPDF Test",
       html_content: @default_html,
       paper_size: "a4",
       orientation: "portrait",
       margin: "1",
       last_generation_ms: nil,
       generating: false,
       error: nil,
       chromic_available: PhoenixKitDocForge.chromic_pdf_available?(),
       chrome_installed: PhoenixKitDocForge.chrome_installed?()
     )}
  end

  @impl true
  def handle_event("update_html", %{"html" => html}, socket) do
    {:noreply, assign(socket, html_content: html)}
  end

  def handle_event("update_options", params, socket) do
    {:noreply,
     assign(socket,
       paper_size: params["paper_size"] || socket.assigns.paper_size,
       orientation: params["orientation"] || socket.assigns.orientation,
       margin: params["margin"] || socket.assigns.margin
     )}
  end

  def handle_event("generate_pdf", _params, socket) do
    if not socket.assigns.chromic_available or not socket.assigns.chrome_installed do
      {:noreply,
       assign(socket, error: "ChromicPDF or Chrome is not available. Check the overview page.")}
    else
      socket = assign(socket, generating: true, error: nil)

      case PhoenixKitDocForge.ChromeSupervisor.ensure_started() do
        :ok ->
          generate_pdf(socket)

        {:error, reason} ->
          {:noreply,
           assign(socket, generating: false, error: "Failed to start Chrome: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("reset_html", _params, socket) do
    {:noreply, assign(socket, html_content: @default_html)}
  end

  defp generate_pdf(socket) do
    html = socket.assigns.html_content
    {margin, _} = Float.parse(socket.assigns.margin)

    {paper_width, paper_height} =
      case socket.assigns.paper_size do
        "letter" -> {8.5, 11.0}
        _ -> {8.27, 11.69}
      end

    {paper_width, paper_height} =
      if socket.assigns.orientation == "landscape",
        do: {paper_height, paper_width},
        else: {paper_width, paper_height}

    print_opts = %{
      paperWidth: paper_width,
      paperHeight: paper_height,
      marginTop: margin,
      marginBottom: margin,
      marginLeft: margin,
      marginRight: margin
    }

    start = System.monotonic_time(:millisecond)

    case ChromicPDF.print_to_pdf({:html, html}, print_to_pdf: print_opts) do
      {:ok, blob} ->
        elapsed = System.monotonic_time(:millisecond) - start

        socket =
          socket
          |> assign(last_generation_ms: elapsed, generating: false)
          |> push_event("download-pdf", %{base64: blob, filename: "chromic-test.pdf"})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         assign(socket, generating: false, error: "PDF generation failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-2xl font-bold">ChromicPDF Test</h2>
          <p class="text-sm text-base-content/60">HTML + CSS → headless Chrome → PDF</p>
        </div>
        <div :if={@last_generation_ms} class="text-right">
          <div class="stat-value text-lg">{@last_generation_ms}ms</div>
          <div class="text-xs text-base-content/60">generation time</div>
        </div>
      </div>

      <%!-- Not Available Warning --%>
      <div :if={not @chromic_available or not @chrome_installed} class="alert alert-warning">
        <span class="hero-exclamation-triangle w-5 h-5" />
        <div>
          <p :if={not @chromic_available} class="font-semibold">ChromicPDF library not loaded</p>
          <p :if={not @chrome_installed}>Chrome/Chromium not found on PATH</p>
          <p class="text-sm mt-1">Add <code>chromic_pdf ~> 1.17</code> to deps and install Chrome to test.</p>
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span>{@error}</span>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
        <%!-- Options Panel --%>
        <div class="lg:col-span-1">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="card-title text-sm">Options</h3>

              <div class="form-control mt-2">
                <label class="label"><span class="label-text text-xs">Paper Size</span></label>
                <select
                  class="select select-bordered select-sm"
                  phx-change="update_options"
                  name="paper_size"
                >
                  <option value="a4" selected={@paper_size == "a4"}>A4</option>
                  <option value="letter" selected={@paper_size == "letter"}>Letter</option>
                </select>
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text text-xs">Orientation</span></label>
                <select
                  class="select select-bordered select-sm"
                  phx-change="update_options"
                  name="orientation"
                >
                  <option value="portrait" selected={@orientation == "portrait"}>Portrait</option>
                  <option value="landscape" selected={@orientation == "landscape"}>Landscape</option>
                </select>
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text text-xs">Margin (inches)</span></label>
                <select
                  class="select select-bordered select-sm"
                  phx-change="update_options"
                  name="margin"
                >
                  <option value="0.5" selected={@margin == "0.5"}>0.5"</option>
                  <option value="0.75" selected={@margin == "0.75"}>0.75"</option>
                  <option value="1" selected={@margin == "1"}>1"</option>
                  <option value="1.5" selected={@margin == "1.5"}>1.5"</option>
                </select>
              </div>

              <button
                class="btn btn-primary btn-sm mt-4"
                phx-click="generate_pdf"
                disabled={@generating or not @chromic_available or not @chrome_installed}
              >
                <span :if={@generating} class="loading loading-spinner loading-xs" />
                {if @generating, do: "Generating...", else: "Generate PDF"}
              </button>

              <button class="btn btn-ghost btn-xs mt-1" phx-click="reset_html">
                Reset to sample
              </button>
            </div>
          </div>
        </div>

        <%!-- HTML Editor --%>
        <div class="lg:col-span-3">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="card-title text-sm">HTML Content</h3>
              <textarea
                class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed"
                rows="30"
                phx-blur="update_html"
                name="html"
              >{@html_content}</textarea>
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
