defmodule PhoenixKitDocumentCreator.Web.Components.CreateDocumentModal do
  @moduledoc """
  Multi-step modal for creating documents.

  Step 1: Choose blank document or pick a template.
  Step 2: If template selected, fill in variable values.
  Step 3: Create document and redirect to editor.
  """
  use Phoenix.Component

  alias PhoenixKitDocumentCreator.DocumentFormat

  attr(:open, :boolean, required: true)
  attr(:templates, :list, default: [])
  attr(:step, :string, default: "choose")
  attr(:selected_template, :any, default: nil)
  attr(:creating, :boolean, default: false)

  def modal(assigns) do
    ~H"""
    <div :if={@open} class="modal modal-open">
      <div class="modal-box max-w-lg">
        <%= case @step do %>
          <% "choose" -> %>
            {render_choose(assigns)}
          <% "variables" -> %>
            {render_variables(assigns)}
          <% _ -> %>
            {render_choose(assigns)}
        <% end %>
      </div>
      <div class="modal-backdrop" phx-click="modal_close"></div>
    </div>
    """
  end

  defp render_choose(assigns) do
    ~H"""
    <h3 class="text-lg font-bold">Create New Document</h3>
    <p class="text-sm text-base-content/60 mt-1">Start from scratch or use a template.</p>

    <div class="mt-4 space-y-3">
      <%!-- Blank document option --%>
      <button
        class="w-full text-left p-4 rounded-lg border-2 border-dashed border-base-content/20 hover:border-primary hover:bg-primary/5 transition-all"
        phx-click="modal_create_blank"
      >
        <div class="flex items-center gap-3">
          <span class="hero-document-plus w-8 h-8 text-base-content/40" />
          <div>
            <p class="font-medium">Blank Document</p>
            <p class="text-xs text-base-content/50">Start with an empty canvas</p>
          </div>
        </div>
      </button>

      <%!-- Template options --%>
      <div :if={@templates != []} class="pt-2">
        <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-2">
          Or use a template
        </p>
        <div class="grid grid-cols-2 gap-3 max-w-md mx-auto">
          <button
            :for={tpl <- @templates}
            class="text-left rounded-lg hover:border-primary hover:bg-primary/5 transition-all overflow-hidden cursor-pointer"
            style="border: 1.5px solid currentColor; box-shadow: 0 4px 16px var(--color-neutral);"
            phx-click="modal_select_template"
            phx-value-uuid={tpl.uuid}
          >
            <%!-- Page preview --%>
            <div style="display:flex;justify-content:center;padding:12px 12px 16px 12px;background:oklch(var(--color-base-200));">
              {render_modal_preview(Map.put(assigns, :tpl, tpl))}
            </div>
            <%!-- Info --%>
            <div class="p-3">
              <p class="font-medium text-sm truncate">{tpl.name}</p>
              <p :if={tpl.description} class="text-xs text-base-content/50 line-clamp-2 mt-1">
                {tpl.description}
              </p>
              <div :if={tpl.variables != []} class="flex flex-wrap gap-1 mt-2">
                <span
                  :for={var <- Enum.take(tpl.variables, 3)}
                  class="badge badge-xs badge-ghost"
                >
                  {var["name"] || var[:name]}
                </span>
                <span
                  :if={length(tpl.variables) > 3}
                  class="badge badge-xs badge-ghost"
                >
                  +{length(tpl.variables) - 3} more
                </span>
              </div>
            </div>
          </button>
        </div>
      </div>

      <div :if={@templates == []} class="text-center py-4 text-sm text-base-content/40">
        No published templates yet. Create one in the template editor.
      </div>
    </div>

    <div class="modal-action">
      <button class="btn btn-ghost btn-sm" phx-click="modal_close">Cancel</button>
    </div>
    """
  end

  defp render_variables(assigns) do
    variables = extract_template_variables(assigns.selected_template)
    assigns = Map.put(assigns, :variables, variables)

    ~H"""
    <h3 class="text-lg font-bold">Fill in Template Variables</h3>
    <p class="text-sm text-base-content/60 mt-1">
      Template: <span class="font-medium">{@selected_template.name}</span>
    </p>

    <form id="create-doc-form" phx-submit="modal_create_from_template" class="mt-4 space-y-3">
      <input type="hidden" name="template_uuid" value={@selected_template.uuid} />

      <div class="form-control">
        <label class="label py-1"><span class="label-text text-xs font-medium">Document Name</span></label>
        <input
          type="text"
          name="doc_name"
          class="input input-bordered input-sm w-full"
          value={@selected_template.name}
          required
        />
      </div>

      <div :if={@variables != []} class="divider text-xs">Template Variables</div>

      <div :for={var <- @variables} class="form-control">
        <label class="label py-1">
          <span class="label-text text-xs font-medium">{var.label}</span>
          <span class="label-text-alt text-xs font-mono text-base-content/40">
            {"{{ #{var.name} }}"}
          </span>
        </label>
        <%= if var.type == :multiline do %>
          <textarea
            name={"var[#{var.name}]"}
            class="textarea textarea-bordered textarea-sm w-full"
            rows="2"
            placeholder={var.label}
          >{var.default || ""}</textarea>
        <% else %>
          <input
            type="text"
            name={"var[#{var.name}]"}
            class="input input-bordered input-sm w-full"
            value={var.default || ""}
            placeholder={var.label}
          />
        <% end %>
      </div>

      <div class="modal-action">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="modal_back">
          Back
        </button>
        <button type="submit" class="btn btn-primary btn-sm" disabled={@creating}>
          <span :if={@creating} class="loading loading-spinner loading-xs" />
          {if @creating, do: "Creating...", else: "Create Document"}
        </button>
      </div>
    </form>
    """
  end

  # ── Page preview ────────────────────────────────────────────────

  defp render_modal_preview(assigns) do
    thumbnail = assigns.tpl.thumbnail
    has_thumbnail = is_binary(thumbnail) and thumbnail != ""
    assigns = Map.merge(assigns, %{has_thumbnail: has_thumbnail, thumbnail: thumbnail})

    ~H"""
    <%= if @has_thumbnail do %>
      <div style="width:160px;height:226px;overflow:hidden;border-radius:4px;background:#fff;border:1px solid currentColor;box-shadow:0 2px 8px var(--color-neutral);position:relative;">
        <iframe src={@thumbnail} sandbox="" scrolling="no" style="width:794px;height:1123px;border:none;pointer-events:none;transform:scale(0.2);transform-origin:top left;" />
      </div>
    <% else %>
      <div style="width:160px;height:226px;border-radius:4px;background:oklch(var(--color-base-300));display:flex;align-items:center;justify-content:center;">
        <span class="hero-document-text w-10 h-10 text-base-content/15" />
      </div>
    <% end %>
    """
  end

  # ── Template variables ─────────────────────────────────────────

  defp extract_template_variables(nil), do: []

  defp extract_template_variables(template) do
    # Try structured variables first, fall back to HTML extraction
    case template.variables do
      vars when is_list(vars) and vars != [] ->
        Enum.map(vars, fn var ->
          %{
            name: var["name"] || var[:name] || "",
            label: var["label"] || var[:label] || humanize(var["name"] || ""),
            type: parse_type(var["type"] || var[:type]),
            default: var["default"] || var[:default]
          }
        end)

      _ ->
        DocumentFormat.extract_variables(template.content_html || "")
        |> Enum.map(fn name ->
          %{name: name, label: humanize(name), type: :text, default: nil}
        end)
    end
  end

  defp parse_type("multiline"), do: :multiline
  defp parse_type(:multiline), do: :multiline
  defp parse_type(_), do: :text

  defp humanize(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
