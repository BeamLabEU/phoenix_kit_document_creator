defmodule PhoenixKitDocForge.Web.TemplateBuilderLive do
  @moduledoc """
  Block-based document template editor.

  Build reusable document templates from blocks (headings, paragraphs, tables,
  signatures, etc.) with Liquid-style variable placeholders. Configure custom
  headers and footers per template.
  """
  use Phoenix.LiveView

  alias PhoenixKitDocForge.TemplateBuilder.{Block, Variable, PdfRenderer}

  @impl true
  def mount(_params, _session, socket) do
    blocks = Block.default_blocks()
    variables = Variable.extract_all(blocks, default_header(), default_footer())

    {:ok,
     assign(socket,
       page_title: "Template Builder",
       template_name: "Service Agreement",
       blocks: blocks,
       selected_block_id: nil,
       header_html: default_header(),
       footer_html: default_footer(),
       variables: variables,
       variable_values: Variable.default_values(),
       config: %{
         paper_size: :a4,
         orientation: "portrait",
         header_height: "25mm",
         footer_height: "20mm"
       },
       generating: false,
       error: nil,
       last_generation_ms: nil,
       show_header_footer: false
     )}
  end

  # --- Block management events ---

  @impl true
  def handle_event("add_block", %{"type" => type_str}, socket) do
    type = String.to_existing_atom(type_str)
    block = Block.new(type)
    blocks = socket.assigns.blocks ++ [block]

    variables =
      Variable.extract_all(blocks, socket.assigns.header_html, socket.assigns.footer_html)

    {:noreply, assign(socket, blocks: blocks, selected_block_id: block.id, variables: variables)}
  end

  def handle_event("select_block", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_block_id: id)}
  end

  def handle_event("delete_block", %{"id" => id}, socket) do
    blocks = Enum.reject(socket.assigns.blocks, &(&1.id == id))

    variables =
      Variable.extract_all(blocks, socket.assigns.header_html, socket.assigns.footer_html)

    selected =
      if socket.assigns.selected_block_id == id, do: nil, else: socket.assigns.selected_block_id

    {:noreply, assign(socket, blocks: blocks, selected_block_id: selected, variables: variables)}
  end

  def handle_event("move_block_up", %{"id" => id}, socket) do
    {:noreply, assign(socket, blocks: move_block(socket.assigns.blocks, id, :up))}
  end

  def handle_event("move_block_down", %{"id" => id}, socket) do
    {:noreply, assign(socket, blocks: move_block(socket.assigns.blocks, id, :down))}
  end

  # --- Block content editing ---

  def handle_event("update_block", %{"id" => id} = params, socket) do
    blocks = update_block_content(socket.assigns.blocks, id, params)

    variables =
      Variable.extract_all(blocks, socket.assigns.header_html, socket.assigns.footer_html)

    {:noreply, assign(socket, blocks: blocks, variables: variables)}
  end

  # --- Table row management ---

  def handle_event("add_table_row", %{"id" => id}, socket) do
    blocks =
      Enum.map(socket.assigns.blocks, fn block ->
        if block.id == id and block.type == :table do
          col_count = length(block.content.columns)
          new_row = List.duplicate("", col_count)
          %{block | content: Map.update!(block.content, :rows, &(&1 ++ [new_row]))}
        else
          block
        end
      end)

    {:noreply, assign(socket, blocks: blocks)}
  end

  def handle_event("remove_table_row", %{"id" => id, "row" => row_str}, socket) do
    row_idx = String.to_integer(row_str)

    blocks =
      Enum.map(socket.assigns.blocks, fn block ->
        if block.id == id and block.type == :table do
          %{block | content: Map.update!(block.content, :rows, &List.delete_at(&1, row_idx))}
        else
          block
        end
      end)

    variables =
      Variable.extract_all(blocks, socket.assigns.header_html, socket.assigns.footer_html)

    {:noreply, assign(socket, blocks: blocks, variables: variables)}
  end

  # --- List item management ---

  def handle_event("add_list_item", %{"id" => id}, socket) do
    blocks =
      Enum.map(socket.assigns.blocks, fn block ->
        if block.id == id and block.type == :list do
          %{block | content: Map.update!(block.content, :items, &(&1 ++ [""]))}
        else
          block
        end
      end)

    {:noreply, assign(socket, blocks: blocks)}
  end

  def handle_event("remove_list_item", %{"id" => id, "index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)

    blocks =
      Enum.map(socket.assigns.blocks, fn block ->
        if block.id == id and block.type == :list do
          %{block | content: Map.update!(block.content, :items, &List.delete_at(&1, idx))}
        else
          block
        end
      end)

    variables =
      Variable.extract_all(blocks, socket.assigns.header_html, socket.assigns.footer_html)

    {:noreply, assign(socket, blocks: blocks, variables: variables)}
  end

  # --- Template settings ---

  def handle_event("update_template_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, template_name: name)}
  end

  def handle_event("update_config", params, socket) do
    config = socket.assigns.config

    config =
      config
      |> maybe_put(:paper_size, params["paper_size"], &String.to_existing_atom/1)
      |> maybe_put(:orientation, params["orientation"])
      |> maybe_put(:header_height, params["header_height"])
      |> maybe_put(:footer_height, params["footer_height"])

    {:noreply, assign(socket, config: config)}
  end

  def handle_event("update_header", %{"header" => html}, socket) do
    variables = Variable.extract_all(socket.assigns.blocks, html, socket.assigns.footer_html)
    {:noreply, assign(socket, header_html: html, variables: variables)}
  end

  def handle_event("update_footer", %{"footer" => html}, socket) do
    variables = Variable.extract_all(socket.assigns.blocks, socket.assigns.header_html, html)
    {:noreply, assign(socket, footer_html: html, variables: variables)}
  end

  def handle_event("toggle_header_footer", _params, socket) do
    {:noreply, assign(socket, show_header_footer: !socket.assigns.show_header_footer)}
  end

  # --- PDF generation ---

  def handle_event("generate_pdf", _params, socket) do
    socket = assign(socket, generating: true, error: nil)
    start = System.monotonic_time(:millisecond)

    case PdfRenderer.render(
           socket.assigns.blocks,
           socket.assigns.variable_values,
           socket.assigns.header_html,
           socket.assigns.footer_html,
           socket.assigns.config
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

  def handle_event("update_variable", %{"name" => name, "value" => value}, socket) do
    values = Map.put(socket.assigns.variable_values, name, value)
    {:noreply, assign(socket, variable_values: values)}
  end

  def handle_event("reset_template", _params, socket) do
    blocks = Block.default_blocks()
    variables = Variable.extract_all(blocks, default_header(), default_footer())

    {:noreply,
     assign(socket,
       template_name: "Service Agreement",
       blocks: blocks,
       selected_block_id: nil,
       header_html: default_header(),
       footer_html: default_footer(),
       variables: variables,
       variable_values: Variable.default_values(),
       error: nil
     )}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-7xl px-4 py-6 gap-4">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-2xl font-bold">Template Builder</h2>
          <p class="text-sm text-base-content/60">Build document templates with blocks + variables → PDF</p>
        </div>
        <div class="flex items-center gap-2">
          <div :if={@last_generation_ms} class="text-right mr-4">
            <div class="stat-value text-lg">{@last_generation_ms}ms</div>
            <div class="text-xs text-base-content/60">generation time</div>
          </div>
          <button class="btn btn-ghost btn-sm" phx-click="reset_template">Reset</button>
          <button
            class="btn btn-primary btn-sm"
            phx-click="generate_pdf"
            disabled={@generating}
          >
            <span :if={@generating} class="loading loading-spinner loading-xs" />
            {if @generating, do: "Generating...", else: "Generate PDF"}
          </button>
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span class="text-sm">{@error}</span>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-12 gap-4">
        <%!-- Left: Block List --%>
        <div class="lg:col-span-3">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4">
              <div class="flex items-center justify-between mb-2">
                <h3 class="card-title text-sm">Blocks</h3>
                <div class="dropdown dropdown-end">
                  <label tabindex="0" class="btn btn-primary btn-xs">+ Add</label>
                  <ul tabindex="0" class="dropdown-content z-[1] menu p-1 shadow bg-base-100 rounded-box w-44">
                    <li :for={type <- Block.block_types()}>
                      <button phx-click="add_block" phx-value-type={type} class="text-xs">
                        <span class={"#{Block.type_icon(type)} w-4 h-4"} />
                        {Block.type_label(type)}
                      </button>
                    </li>
                  </ul>
                </div>
              </div>

              <div class="space-y-1">
                <div
                  :for={block <- @blocks}
                  class={"flex items-center gap-1 p-2 rounded cursor-pointer text-xs #{if block.id == @selected_block_id, do: "bg-primary/10 border border-primary/30", else: "hover:bg-base-200"}"}
                  phx-click="select_block"
                  phx-value-id={block.id}
                >
                  <span class={"#{Block.type_icon(block.type)} w-3.5 h-3.5 shrink-0"} />
                  <span class="flex-1 truncate">{block_preview(block)}</span>
                  <div class="flex gap-0.5 shrink-0">
                    <button
                      class="btn btn-ghost btn-xs px-1"
                      phx-click="move_block_up"
                      phx-value-id={block.id}
                      title="Move up"
                    >↑</button>
                    <button
                      class="btn btn-ghost btn-xs px-1"
                      phx-click="move_block_down"
                      phx-value-id={block.id}
                      title="Move down"
                    >↓</button>
                    <button
                      class="btn btn-ghost btn-xs px-1 text-error"
                      phx-click="delete_block"
                      phx-value-id={block.id}
                      title="Delete"
                    >×</button>
                  </div>
                </div>
              </div>

              <p :if={@blocks == []} class="text-xs text-base-content/40 text-center py-4">
                No blocks yet. Click "+ Add" to start building.
              </p>
            </div>
          </div>
        </div>

        <%!-- Center: Block Editor --%>
        <div class="lg:col-span-5">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4">
              <h3 class="card-title text-sm">
                {if @selected_block_id, do: "Edit Block", else: "Select a Block"}
              </h3>

              <%= if block = selected_block(@blocks, @selected_block_id) do %>
                {render_block_editor(assigns, block)}
              <% else %>
                <p class="text-xs text-base-content/40 text-center py-8">
                  Select a block from the list to edit its content.
                </p>
              <% end %>
            </div>
          </div>

          <%!-- Header/Footer Editor --%>
          <div class="card bg-base-100 shadow-xl mt-4">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <h3 class="card-title text-sm">Header & Footer</h3>
                <button class="btn btn-ghost btn-xs" phx-click="toggle_header_footer">
                  {if @show_header_footer, do: "Hide", else: "Show"}
                </button>
              </div>
              <div :if={@show_header_footer} class="space-y-3 mt-2">
                <div class="form-control">
                  <label class="label"><span class="label-text text-xs">Header HTML</span></label>
                  <textarea
                    class="textarea textarea-bordered textarea-sm font-mono text-xs"
                    rows="4"
                    phx-blur="update_header"
                    name="header"
                  >{@header_html}</textarea>
                  <label class="label">
                    <span class="label-text-alt text-xs text-base-content/50">
                      Use {"{{ variable }}"} for values. &lt;span class="pageNumber"&gt; for page numbers.
                    </span>
                  </label>
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text text-xs">Footer HTML</span></label>
                  <textarea
                    class="textarea textarea-bordered textarea-sm font-mono text-xs"
                    rows="4"
                    phx-blur="update_footer"
                    name="footer"
                  >{@footer_html}</textarea>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Right: Settings + Variables --%>
        <div class="lg:col-span-4">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body p-4">
              <h3 class="card-title text-sm">Template Settings</h3>

              <div class="form-control mt-2">
                <label class="label"><span class="label-text text-xs">Template Name</span></label>
                <input
                  type="text"
                  class="input input-bordered input-sm"
                  value={@template_name}
                  phx-blur="update_template_name"
                  name="name"
                />
              </div>

              <div class="grid grid-cols-2 gap-2">
                <div class="form-control">
                  <label class="label"><span class="label-text text-xs">Paper Size</span></label>
                  <select class="select select-bordered select-sm" phx-change="update_config" name="paper_size">
                    <option value="a4" selected={@config.paper_size == :a4}>A4</option>
                    <option value="us_letter" selected={@config.paper_size == :us_letter}>Letter</option>
                  </select>
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text text-xs">Orientation</span></label>
                  <select class="select select-bordered select-sm" phx-change="update_config" name="orientation">
                    <option value="portrait" selected={@config.orientation == "portrait"}>Portrait</option>
                    <option value="landscape" selected={@config.orientation == "landscape"}>Landscape</option>
                  </select>
                </div>
              </div>

              <div class="grid grid-cols-2 gap-2">
                <div class="form-control">
                  <label class="label"><span class="label-text text-xs">Header Height</span></label>
                  <input type="text" class="input input-bordered input-sm" value={@config.header_height} phx-blur="update_config" name="header_height" />
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text text-xs">Footer Height</span></label>
                  <input type="text" class="input input-bordered input-sm" value={@config.footer_height} phx-blur="update_config" name="footer_height" />
                </div>
              </div>
            </div>
          </div>

          <%!-- Variables --%>
          <div class="card bg-base-100 shadow-xl mt-4">
            <div class="card-body p-4">
              <h3 class="card-title text-sm">Variables</h3>
              <p class="text-xs text-base-content/50">
                Auto-detected from blocks. Fill values for PDF preview.
              </p>

              <div :if={@variables == []} class="text-xs text-base-content/40 text-center py-4">
                No variables found. Use {"{{ name }}"} in block text.
              </div>

              <div :for={var_name <- @variables} class="form-control mt-1">
                <label class="label py-0.5">
                  <span class="label-text text-xs font-mono">{"{{ #{var_name} }}"}</span>
                </label>
                <input
                  :if={var_name not in ["description", "notes"]}
                  type="text"
                  class="input input-bordered input-xs"
                  value={Map.get(@variable_values, var_name, "")}
                  phx-blur="update_variable"
                  phx-value-name={var_name}
                  name="value"
                />
                <textarea
                  :if={var_name in ["description", "notes"]}
                  class="textarea textarea-bordered textarea-xs text-xs"
                  rows="2"
                  phx-blur="update_variable"
                  phx-value-name={var_name}
                  name="value"
                >{Map.get(@variable_values, var_name, "")}</textarea>
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

  # --- Block editor renderers ---

  defp render_block_editor(assigns, %Block{type: :heading} = block) do
    assigns = Map.put(assigns, :block, block)

    ~H"""
    <div class="space-y-2 mt-2">
      <div class="form-control">
        <label class="label"><span class="label-text text-xs">Level</span></label>
        <select class="select select-bordered select-sm" phx-change="update_block" phx-value-id={@block.id} name="level">
          <option :for={l <- 1..3} value={l} selected={@block.content.level == l}>H{l}</option>
        </select>
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text text-xs">Text</span></label>
        <input type="text" class="input input-bordered input-sm" value={@block.content.text} phx-blur="update_block" phx-value-id={@block.id} name="text" />
      </div>
      <.variable_hint variables={@variables} />
    </div>
    """
  end

  defp render_block_editor(assigns, %Block{type: :paragraph} = block) do
    assigns = Map.put(assigns, :block, block)

    ~H"""
    <div class="space-y-2 mt-2">
      <div class="form-control">
        <label class="label"><span class="label-text text-xs">Text</span></label>
        <textarea class="textarea textarea-bordered textarea-sm" rows="5" phx-blur="update_block" phx-value-id={@block.id} name="text">{@block.content.text}</textarea>
      </div>
      <.variable_hint variables={@variables} />
    </div>
    """
  end

  defp render_block_editor(assigns, %Block{type: :table} = block) do
    assigns = Map.put(assigns, :block, block)

    ~H"""
    <div class="space-y-2 mt-2">
      <label class="label"><span class="label-text text-xs">Columns</span></label>
      <div class="flex gap-1">
        <input
          :for={{col, ci} <- Enum.with_index(@block.content.columns)}
          type="text"
          class="input input-bordered input-xs flex-1"
          value={col}
          phx-blur="update_block"
          phx-value-id={@block.id}
          name={"col_#{ci}"}
        />
      </div>

      <label class="label"><span class="label-text text-xs">Rows</span></label>
      <div :for={{row, ri} <- Enum.with_index(@block.content.rows)} class="flex gap-1 items-center">
        <input
          :for={{cell, ci} <- Enum.with_index(row)}
          type="text"
          class="input input-bordered input-xs flex-1"
          value={cell}
          phx-blur="update_block"
          phx-value-id={@block.id}
          name={"cell_#{ri}_#{ci}"}
        />
        <button class="btn btn-ghost btn-xs text-error px-1" phx-click="remove_table_row" phx-value-id={@block.id} phx-value-row={ri}>×</button>
      </div>
      <button class="btn btn-ghost btn-xs" phx-click="add_table_row" phx-value-id={@block.id}>+ Row</button>
      <.variable_hint variables={@variables} />
    </div>
    """
  end

  defp render_block_editor(assigns, %Block{type: :list} = block) do
    assigns = Map.put(assigns, :block, block)

    ~H"""
    <div class="space-y-2 mt-2">
      <div class="form-control">
        <label class="label"><span class="label-text text-xs">Style</span></label>
        <select class="select select-bordered select-sm" phx-change="update_block" phx-value-id={@block.id} name="list_style">
          <option value="unordered" selected={@block.content.style == :unordered}>Bullet</option>
          <option value="ordered" selected={@block.content.style == :ordered}>Numbered</option>
        </select>
      </div>
      <label class="label"><span class="label-text text-xs">Items</span></label>
      <div :for={{item, idx} <- Enum.with_index(@block.content.items)} class="flex gap-1 items-center">
        <input type="text" class="input input-bordered input-xs flex-1" value={item} phx-blur="update_block" phx-value-id={@block.id} name={"item_#{idx}"} />
        <button class="btn btn-ghost btn-xs text-error px-1" phx-click="remove_list_item" phx-value-id={@block.id} phx-value-index={idx}>×</button>
      </div>
      <button class="btn btn-ghost btn-xs" phx-click="add_list_item" phx-value-id={@block.id}>+ Item</button>
      <.variable_hint variables={@variables} />
    </div>
    """
  end

  defp render_block_editor(assigns, %Block{type: :signature} = block) do
    assigns = Map.put(assigns, :block, block)

    ~H"""
    <div class="space-y-2 mt-2">
      <div class="form-control">
        <label class="label"><span class="label-text text-xs">Columns</span></label>
        <select class="select select-bordered select-sm" phx-change="update_block" phx-value-id={@block.id} name="sig_columns">
          <option :for={n <- 1..3} value={n} selected={@block.content.columns == n}>{n}</option>
        </select>
      </div>
      <label class="label"><span class="label-text text-xs">Labels</span></label>
      <input
        :for={{label, idx} <- Enum.with_index(@block.content.labels)}
        type="text"
        class="input input-bordered input-xs w-full mb-1"
        value={label}
        phx-blur="update_block"
        phx-value-id={@block.id}
        name={"sig_label_#{idx}"}
      />
      <.variable_hint variables={@variables} />
    </div>
    """
  end

  defp render_block_editor(assigns, %Block{type: :spacer} = block) do
    assigns = Map.put(assigns, :block, block)

    ~H"""
    <div class="space-y-2 mt-2">
      <div class="form-control">
        <label class="label"><span class="label-text text-xs">Height</span></label>
        <input type="text" class="input input-bordered input-sm" value={@block.content.height} phx-blur="update_block" phx-value-id={@block.id} name="height" />
      </div>
    </div>
    """
  end

  defp render_block_editor(assigns, %Block{type: :image_placeholder} = block) do
    assigns = Map.put(assigns, :block, block)

    ~H"""
    <div class="space-y-2 mt-2">
      <div class="form-control">
        <label class="label"><span class="label-text text-xs">Label</span></label>
        <input type="text" class="input input-bordered input-sm" value={@block.content.label} phx-blur="update_block" phx-value-id={@block.id} name="img_label" />
      </div>
      <div class="grid grid-cols-2 gap-2">
        <div class="form-control">
          <label class="label"><span class="label-text text-xs">Width</span></label>
          <input type="text" class="input input-bordered input-sm" value={@block.content.width} phx-blur="update_block" phx-value-id={@block.id} name="img_width" />
        </div>
        <div class="form-control">
          <label class="label"><span class="label-text text-xs">Height</span></label>
          <input type="text" class="input input-bordered input-sm" value={@block.content.height} phx-blur="update_block" phx-value-id={@block.id} name="img_height" />
        </div>
      </div>
    </div>
    """
  end

  defp render_block_editor(assigns, %Block{type: type}) when type in [:divider, :page_break] do
    ~H"""
    <p class="text-xs text-base-content/50 mt-2">
      This block has no editable properties.
    </p>
    """
  end

  # --- Components ---

  attr(:variables, :list, required: true)

  defp variable_hint(assigns) do
    ~H"""
    <div :if={@variables != []} class="text-xs text-base-content/40 mt-1">
      Variables: {Enum.map(@variables, &"{{ #{&1} }}") |> Enum.join(", ")}
    </div>
    """
  end

  # --- Helpers ---

  defp selected_block(_blocks, nil), do: nil
  defp selected_block(blocks, id), do: Enum.find(blocks, &(&1.id == id))

  defp block_preview(%Block{type: :heading, content: %{text: t}}),
    do: if(t == "", do: "Heading", else: String.slice(t, 0, 30))

  defp block_preview(%Block{type: :paragraph, content: %{text: t}}),
    do: if(t == "", do: "Paragraph", else: String.slice(t, 0, 30))

  defp block_preview(%Block{type: :table}), do: "Table"

  defp block_preview(%Block{type: :list, content: %{style: s}}),
    do: "#{if s == :ordered, do: "Numbered", else: "Bullet"} List"

  defp block_preview(%Block{type: type}), do: Block.type_label(type)

  defp move_block(blocks, id, direction) do
    idx = Enum.find_index(blocks, &(&1.id == id))

    cond do
      idx == nil -> blocks
      direction == :up and idx == 0 -> blocks
      direction == :down and idx == length(blocks) - 1 -> blocks
      direction == :up -> swap(blocks, idx - 1, idx)
      direction == :down -> swap(blocks, idx, idx + 1)
    end
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)

    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  defp update_block_content(blocks, id, params) do
    Enum.map(blocks, fn block ->
      if block.id == id do
        update_block_from_params(block, params)
      else
        block
      end
    end)
  end

  defp update_block_from_params(%Block{type: :heading} = block, params) do
    content = block.content

    content =
      if params["level"],
        do: Map.put(content, :level, String.to_integer(params["level"])),
        else: content

    content = if params["text"], do: Map.put(content, :text, params["text"]), else: content
    %{block | content: content}
  end

  defp update_block_from_params(%Block{type: :paragraph} = block, params) do
    if params["text"],
      do: %{block | content: Map.put(block.content, :text, params["text"])},
      else: block
  end

  defp update_block_from_params(%Block{type: :table} = block, params) do
    content = block.content

    # Update columns
    content =
      Enum.reduce(0..(length(content.columns) - 1), content, fn ci, acc ->
        case params["col_#{ci}"] do
          nil -> acc
          val -> Map.update!(acc, :columns, &List.replace_at(&1, ci, val))
        end
      end)

    # Update cells
    content =
      Enum.reduce(Enum.with_index(content.rows), content, fn {row, ri}, acc ->
        new_row =
          Enum.reduce(0..(length(row) - 1), row, fn ci, r ->
            case params["cell_#{ri}_#{ci}"] do
              nil -> r
              val -> List.replace_at(r, ci, val)
            end
          end)

        Map.update!(acc, :rows, &List.replace_at(&1, ri, new_row))
      end)

    %{block | content: content}
  end

  defp update_block_from_params(%Block{type: :list} = block, params) do
    content = block.content

    content =
      if params["list_style"],
        do: Map.put(content, :style, String.to_existing_atom(params["list_style"])),
        else: content

    content =
      Enum.reduce(0..(length(content.items) - 1), content, fn idx, acc ->
        case params["item_#{idx}"] do
          nil -> acc
          val -> Map.update!(acc, :items, &List.replace_at(&1, idx, val))
        end
      end)

    %{block | content: content}
  end

  defp update_block_from_params(%Block{type: :signature} = block, params) do
    content = block.content

    content =
      if params["sig_columns"],
        do: Map.put(content, :columns, String.to_integer(params["sig_columns"])),
        else: content

    content =
      Enum.reduce(0..(length(content.labels) - 1), content, fn idx, acc ->
        case params["sig_label_#{idx}"] do
          nil -> acc
          val -> Map.update!(acc, :labels, &List.replace_at(&1, idx, val))
        end
      end)

    %{block | content: content}
  end

  defp update_block_from_params(%Block{type: :spacer} = block, params) do
    if params["height"],
      do: %{block | content: Map.put(block.content, :height, params["height"])},
      else: block
  end

  defp update_block_from_params(%Block{type: :image_placeholder} = block, params) do
    content = block.content

    content =
      if params["img_label"], do: Map.put(content, :label, params["img_label"]), else: content

    content =
      if params["img_width"], do: Map.put(content, :width, params["img_width"]), else: content

    content =
      if params["img_height"], do: Map.put(content, :height, params["img_height"]), else: content

    %{block | content: content}
  end

  defp update_block_from_params(block, _params), do: block

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, key, value, transform), do: Map.put(map, key, transform.(value))

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp default_header do
    ~s(<div style="width: 100%; font-size: 8pt; color: #666; padding: 0 40px; display: flex; justify-content: space-between;"><span>{{ company }} — {{ template_name }}</span><span>SA-2026-0042</span></div>)
  end

  defp default_footer do
    ~s(<div style="width: 100%; font-size: 8pt; color: #999; padding: 0 40px; display: flex; justify-content: space-between;"><span>Confidential</span><span>Page <span class="pageNumber"></span> of <span class="totalPages"></span></span></div>)
  end
end
