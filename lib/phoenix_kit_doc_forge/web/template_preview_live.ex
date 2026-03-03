defmodule PhoenixKitDocForge.Web.TemplatePreviewLive do
  @moduledoc """
  Template preview and PDF generation page.

  Select a sample template, fill in variable values, preview the rendered HTML,
  and generate a downloadable PDF with custom header/footer.
  """
  use Phoenix.LiveView

  alias PhoenixKitDocForge.TemplateBuilder.{Block, Variable, PdfRenderer}

  @sample_templates %{
    "service_agreement" => %{
      name: "Service Agreement",
      blocks: :default,
      header:
        ~s(<div style="width: 100%; font-size: 8pt; color: #666; padding: 0 40px; display: flex; justify-content: space-between;"><span>{{ company }} — Service Agreement</span><span>SA-2026-0042</span></div>),
      footer:
        ~s(<div style="width: 100%; font-size: 8pt; color: #999; padding: 0 40px; display: flex; justify-content: space-between;"><span>Confidential</span><span>Page <span class="pageNumber"></span> of <span class="totalPages"></span></span></div>),
      values: Variable.default_values()
    },
    "invoice" => %{
      name: "Invoice",
      blocks: :invoice,
      header:
        ~s(<div style="width: 100%; font-size: 8pt; color: #666; padding: 0 40px; display: flex; justify-content: space-between;"><span>{{ company }}</span><span>INVOICE</span></div>),
      footer:
        ~s(<div style="width: 100%; font-size: 8pt; color: #999; padding: 0 40px; display: flex; justify-content: space-between;"><span>Thank you for your business</span><span>Page <span class="pageNumber"></span></span></div>),
      values: %{
        "company" => "Acme Development LLC",
        "client_name" => "Widget Corp International",
        "invoice_number" => "INV-2026-0087",
        "invoice_date" => "March 1, 2026",
        "due_date" => "March 31, 2026",
        "amount" => "$38,000"
      }
    },
    "letter" => %{
      name: "Business Letter",
      blocks: :letter,
      header: "",
      footer:
        ~s(<div style="width: 100%; font-size: 8pt; color: #999; padding: 0 40px; text-align: center;"><span>{{ company }} · 123 Innovation Drive · San Francisco, CA 94102</span></div>),
      values: %{
        "company" => "Acme Development LLC",
        "client_name" => "Widget Corp International",
        "date" => "March 1, 2026",
        "subject" => "Project Kickoff Confirmation",
        "body" =>
          "We are pleased to confirm the commencement of the software development project as outlined in our Service Agreement SA-2026-0042.\n\nOur team will begin work on March 3, 2026. The project manager assigned to your account is Sarah Chen, who will serve as your primary point of contact throughout the engagement.\n\nPlease do not hesitate to reach out if you have any questions.",
        "sender_name" => "John Smith",
        "sender_title" => "CEO"
      }
    }
  }

  @impl true
  def mount(_params, _session, socket) do
    template = @sample_templates["service_agreement"]
    blocks = resolve_blocks(template.blocks)
    variables = Variable.extract_all(blocks, template.header, template.footer)

    {:ok,
     assign(socket,
       page_title: "Template Preview",
       sample_templates: @sample_templates,
       selected_template: "service_agreement",
       template_name: template.name,
       blocks: blocks,
       header_html: template.header,
       footer_html: template.footer,
       variables: variables,
       variable_values: template.values,
       preview_html: nil,
       generating: false,
       error: nil,
       last_generation_ms: nil,
       chrome_available:
         PhoenixKitDocForge.chromic_pdf_available?() and PhoenixKitDocForge.chrome_installed?()
     )}
  end

  @impl true
  def handle_event("select_template", %{"template" => key}, socket) do
    case Map.get(@sample_templates, key) do
      nil ->
        {:noreply, socket}

      template ->
        blocks = resolve_blocks(template.blocks)
        variables = Variable.extract_all(blocks, template.header, template.footer)

        {:noreply,
         assign(socket,
           selected_template: key,
           template_name: template.name,
           blocks: blocks,
           header_html: template.header,
           footer_html: template.footer,
           variables: variables,
           variable_values: template.values,
           preview_html: nil,
           error: nil
         )}
    end
  end

  def handle_event("update_variable", %{"name" => name, "value" => value}, socket) do
    values = Map.put(socket.assigns.variable_values, name, value)
    {:noreply, assign(socket, variable_values: values, preview_html: nil)}
  end

  def handle_event("preview", _params, socket) do
    html = PdfRenderer.render_to_html(socket.assigns.blocks, socket.assigns.variable_values)
    {:noreply, assign(socket, preview_html: html)}
  end

  def handle_event("generate_pdf", _params, socket) do
    socket = assign(socket, generating: true, error: nil)
    start = System.monotonic_time(:millisecond)

    case PdfRenderer.render(
           socket.assigns.blocks,
           socket.assigns.variable_values,
           socket.assigns.header_html,
           socket.assigns.footer_html
         ) do
      {:ok, pdf_binary} ->
        elapsed = System.monotonic_time(:millisecond) - start
        base64 = Base.encode64(pdf_binary)

        socket =
          socket
          |> assign(last_generation_ms: elapsed, generating: false)
          |> push_event("download-pdf", %{
            base64: base64,
            filename: "#{slugify(socket.assigns.template_name)}.pdf"
          })

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           generating: false,
           error: "PDF generation failed: #{inspect(reason)}"
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-4">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-2xl font-bold">Template Preview</h2>
          <p class="text-sm text-base-content/60">Fill variables, preview, and generate PDF</p>
        </div>
        <div class="flex items-center gap-2">
          <div :if={@last_generation_ms} class="text-right mr-4">
            <div class="stat-value text-lg">{@last_generation_ms}ms</div>
            <div class="text-xs text-base-content/60">generation time</div>
          </div>
        </div>
      </div>

      <%!-- Not Available Warning --%>
      <div :if={not @chrome_available} class="alert alert-warning">
        <span class="hero-exclamation-triangle w-5 h-5" />
        <div>
          <p class="font-semibold">ChromicPDF or Chrome not available</p>
          <p class="text-sm mt-1">PDF generation requires Chrome/Chromium and the ChromicPDF library.</p>
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span class="text-sm">{@error}</span>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <%!-- Left: Template Select + Variables --%>
        <div class="lg:col-span-1 space-y-4">
          <%!-- Template Selector --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4">
              <h3 class="card-title text-sm">Template</h3>
              <select class="select select-bordered select-sm w-full mt-1" phx-change="select_template" name="template">
                <option :for={{key, tmpl} <- @sample_templates} value={key} selected={key == @selected_template}>
                  {tmpl.name}
                </option>
              </select>
            </div>
          </div>

          <%!-- Variable Form --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4">
              <h3 class="card-title text-sm">Variables</h3>
              <p class="text-xs text-base-content/50">
                Fill in values for the template placeholders.
              </p>

              <div :for={var_name <- @variables} class="form-control mt-1">
                <label class="label py-0.5">
                  <span class="label-text text-xs">{humanize(var_name)}</span>
                </label>
                <textarea
                  :if={var_name in ~w(description body notes)}
                  class="textarea textarea-bordered textarea-sm text-xs"
                  rows="3"
                  phx-blur="update_variable"
                  phx-value-name={var_name}
                  name="value"
                >{Map.get(@variable_values, var_name, "")}</textarea>
                <input
                  :if={var_name not in ~w(description body notes)}
                  type="text"
                  class="input input-bordered input-sm"
                  value={Map.get(@variable_values, var_name, "")}
                  phx-blur="update_variable"
                  phx-value-name={var_name}
                  name="value"
                />
              </div>

              <div class="flex gap-2 mt-3">
                <button class="btn btn-outline btn-sm flex-1" phx-click="preview">
                  Preview HTML
                </button>
                <button
                  class="btn btn-primary btn-sm flex-1"
                  phx-click="generate_pdf"
                  disabled={@generating or not @chrome_available}
                >
                  <span :if={@generating} class="loading loading-spinner loading-xs" />
                  {if @generating, do: "Generating...", else: "Generate PDF"}
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Right: Preview --%>
        <div class="lg:col-span-2">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4">
              <h3 class="card-title text-sm">Preview</h3>

              <div :if={@preview_html} class="mt-2 border border-base-300 rounded-lg bg-white p-6 shadow-inner">
                <iframe
                  srcdoc={@preview_html}
                  class="w-full border-0"
                  style="min-height: 600px;"
                  sandbox="allow-same-origin"
                />
              </div>

              <div :if={!@preview_html} class="text-center py-12 text-base-content/40">
                <span class="hero-document-text w-12 h-12 mx-auto mb-2" />
                <p class="text-sm">Click "Preview HTML" to see the rendered template</p>
                <p class="text-xs mt-1">or "Generate PDF" to download directly</p>
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

  # --- Sample template blocks ---

  defp resolve_blocks(:default), do: Block.default_blocks()

  defp resolve_blocks(:invoice) do
    [
      Block.new(:heading, %{level: 1, text: "INVOICE"}),
      Block.new(:paragraph, %{text: "Invoice \#{{ invoice_number }}"}),
      Block.new(:paragraph, %{text: "Date: {{ invoice_date }}  |  Due: {{ due_date }}"}),
      Block.new(:divider),
      Block.new(:heading, %{level: 2, text: "Bill To"}),
      Block.new(:paragraph, %{text: "{{ client_name }}"}),
      Block.new(:heading, %{level: 2, text: "Services"}),
      Block.new(:table, %{
        columns: ["Service", "Hours", "Rate", "Amount"],
        rows: [
          ["Backend Development", "120", "$150/hr", "$18,000"],
          ["Frontend Development", "80", "$140/hr", "$11,200"],
          ["UI/UX Design", "40", "$130/hr", "$5,200"],
          ["Project Management", "30", "$120/hr", "$3,600"],
          ["Total", "", "", "{{ amount }}"]
        ]
      }),
      Block.new(:divider),
      Block.new(:paragraph, %{
        text: "Payment due within 30 days. Make checks payable to {{ company }}."
      }),
      Block.new(:paragraph, %{text: "Thank you for your business."})
    ]
  end

  defp resolve_blocks(:letter) do
    [
      Block.new(:paragraph, %{text: "{{ date }}"}),
      Block.new(:spacer, %{height: "20px"}),
      Block.new(:paragraph, %{text: "{{ client_name }}\n456 Business Avenue\nNew York, NY 10001"}),
      Block.new(:spacer, %{height: "20px"}),
      Block.new(:paragraph, %{text: "Re: {{ subject }}"}),
      Block.new(:spacer, %{height: "10px"}),
      Block.new(:paragraph, %{text: "Dear {{ client_name }},"}),
      Block.new(:paragraph, %{text: "{{ body }}"}),
      Block.new(:paragraph, %{text: "Sincerely,"}),
      Block.new(:spacer, %{height: "40px"}),
      Block.new(:paragraph, %{text: "{{ sender_name }}\n{{ sender_title }}\n{{ company }}"})
    ]
  end

  defp resolve_blocks(_), do: []

  defp humanize(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
