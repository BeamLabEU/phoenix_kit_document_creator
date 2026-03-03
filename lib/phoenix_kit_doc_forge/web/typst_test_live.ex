defmodule PhoenixKitDocForge.Web.TypstTestLive do
  @moduledoc """
  Interactive testing page for Typst PDF generation.

  Fill in template variables, optionally edit the Typst template source,
  and generate a PDF via the Typst Rust NIF.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    template_source = load_default_template()

    {:ok,
     assign(socket,
       page_title: "Typst Test",
       template_source: template_source,
       client_name: "Widget Corp International",
       company: "Acme Development LLC",
       contract_date: "February 28, 2026",
       amount: "38,000",
       description:
         "The Provider agrees to deliver comprehensive software development services including backend API development, frontend web application, UI/UX design, and project management.",
       last_generation_ms: nil,
       generating: false,
       error: nil,
       typst_available: PhoenixKitDocForge.typst_available?()
     )}
  end

  defp load_default_template do
    priv_path = Application.app_dir(:phoenix_kit_doc_forge, "priv/templates/sample_contract.typ")

    if File.exists?(priv_path) do
      File.read!(priv_path)
    else
      "// sample_contract.typ not found at #{priv_path}\n// Check that priv/templates/ is included in the package."
    end
  end

  @impl true
  def handle_event("update_form", params, socket) do
    {:noreply,
     assign(socket,
       client_name: params["client_name"] || socket.assigns.client_name,
       company: params["company"] || socket.assigns.company,
       contract_date: params["contract_date"] || socket.assigns.contract_date,
       amount: params["amount"] || socket.assigns.amount,
       description: params["description"] || socket.assigns.description
     )}
  end

  def handle_event("update_template", %{"template" => template}, socket) do
    {:noreply, assign(socket, template_source: template)}
  end

  def handle_event("generate_pdf", _params, socket) do
    if not socket.assigns.typst_available do
      {:noreply, assign(socket, error: "Typst NIF is not available. Check dependencies.")}
    else
      socket = assign(socket, generating: true, error: nil)

      bindings = [
        client_name: socket.assigns.client_name,
        company: socket.assigns.company,
        contract_date: socket.assigns.contract_date,
        amount: socket.assigns.amount,
        description: socket.assigns.description
      ]

      start = System.monotonic_time(:millisecond)

      case Typst.render_to_pdf(socket.assigns.template_source, bindings) do
        {:ok, pdf_binary} ->
          elapsed = System.monotonic_time(:millisecond) - start
          base64 = Base.encode64(pdf_binary)

          socket =
            socket
            |> assign(last_generation_ms: elapsed, generating: false)
            |> push_event("download-pdf", %{base64: base64, filename: "typst-test.pdf"})

          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             generating: false,
             error: "Typst compilation failed: #{inspect(reason)}"
           )}
      end
    end
  end

  def handle_event("reset_template", _params, socket) do
    {:noreply, assign(socket, template_source: load_default_template())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-2xl font-bold">Typst Test</h2>
          <p class="text-sm text-base-content/60">Typst markup → Rust NIF → PDF</p>
        </div>
        <div :if={@last_generation_ms} class="text-right">
          <div class="stat-value text-lg">{@last_generation_ms}ms</div>
          <div class="text-xs text-base-content/60">generation time</div>
        </div>
      </div>

      <%!-- Not Available Warning --%>
      <div :if={not @typst_available} class="alert alert-warning">
        <span class="hero-exclamation-triangle w-5 h-5" />
        <div>
          <p class="font-semibold">Typst NIF not loaded</p>
          <p class="text-sm mt-1">Add <code>typst ~> 0.2.3</code> to deps and run <code>mix deps.get</code>.</p>
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span class="text-sm">{@error}</span>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Form Fields --%>
        <div class="lg:col-span-1">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="card-title text-sm">Template Variables</h3>
              <p class="text-xs text-base-content/60">
                These values replace <code>&lt;%= variable %&gt;</code> in the template.
              </p>

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
                <label class="label"><span class="label-text text-xs">Amount</span></label>
                <input
                  type="text"
                  class="input input-bordered input-sm"
                  value={@amount}
                  phx-blur="update_form"
                  name="amount"
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text text-xs">Description</span></label>
                <textarea
                  class="textarea textarea-bordered textarea-sm"
                  rows="3"
                  phx-blur="update_form"
                  name="description"
                >{@description}</textarea>
              </div>

              <button
                class="btn btn-primary btn-sm mt-4"
                phx-click="generate_pdf"
                disabled={@generating or not @typst_available}
              >
                <span :if={@generating} class="loading loading-spinner loading-xs" />
                {if @generating, do: "Generating...", else: "Generate PDF"}
              </button>
            </div>
          </div>
        </div>

        <%!-- Template Editor --%>
        <div class="lg:col-span-2">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h3 class="card-title text-sm">Typst Template</h3>
                <button class="btn btn-ghost btn-xs" phx-click="reset_template">
                  Reset to sample
                </button>
              </div>
              <p class="text-xs text-base-content/60">
                Edit the Typst markup below. Uses EEx-style <code>&lt;%= %&gt;</code> bindings.
              </p>
              <textarea
                class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed"
                rows="30"
                phx-blur="update_template"
                name="template"
              >{@template_source}</textarea>
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
