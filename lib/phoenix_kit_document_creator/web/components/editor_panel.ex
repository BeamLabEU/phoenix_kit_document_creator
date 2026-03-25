defmodule PhoenixKitDocumentCreator.Web.Components.EditorPanel do
  @moduledoc """
  Shared GrapesJS editor panel component used by both the template and document editors.

  Renders the page frame with header/footer regions, the GrapesJS container,
  the blocks panel, and the required CSS overrides.
  """
  use Phoenix.Component

  attr(:id, :string, required: true, doc: "Unique prefix for all element IDs")

  attr(:hook, :string,
    required: true,
    doc: "Phoenix hook name (GrapesJSTemplateEditor or GrapesJSDocumentEditor)"
  )

  attr(:save_event, :string, required: true, doc: "LiveView event name for saving")
  attr(:template_vars, :boolean, default: false, doc: "Whether to show template variable blocks")

  def editor_panel(assigns) do
    ~H"""
    <div class="flex-1">
      <div
        id={"#{@id}-wrapper"}
        phx-hook={@hook}
        phx-update="ignore"
        style="display:flex;width:100%;"
        data-editor-id={"#{@id}-grapesjs"}
        data-wrapper-id={"#{@id}-wrapper"}
        data-page-frame-id={"#{@id}-page-frame"}
        data-right-panel-id={"#{@id}-right-panel"}
        data-blocks-panel-id={"#{@id}-blocks-panel"}
        data-paper-size-id={"#{@id}-paper-size"}
        data-name-id={"#{@id}-name"}
        data-save-event={@save_event}
        data-template-vars={to_string(@template_vars)}
      >
        <%!-- Page frame with header/footer regions --%>
        <div
          id={"#{@id}-page-frame"}
          style="display:flex;flex-direction:column;width:794px;min-width:794px;height:1123px;background:#fff;border-radius:4px 0 0 4px;overflow:hidden;position:relative;"
        >
          <%!-- Header region (non-editable, hidden by default) --%>
          <div id="template-header-region" style="flex-shrink:0;height:0px;overflow:hidden;display:none;position:relative;">
            <iframe id="template-header-iframe" style="width:100%;height:100%;border:none;pointer-events:none;" sandbox="" scrolling="no"></iframe>
            <div style="position:absolute;inset:0;background:rgba(0,0,0,0.03);pointer-events:none;"></div>
          </div>
          <div id="template-header-separator" style="border-top:2px dashed #cbd5e1;flex-shrink:0;display:none;"></div>

          <%!-- GrapesJS editable body area --%>
          <div id={"#{@id}-grapesjs"} style="flex:1 1 auto;overflow:hidden;"></div>

          <%!-- Footer region (non-editable, hidden by default) --%>
          <div id="template-footer-separator" style="border-top:2px dashed #cbd5e1;flex-shrink:0;display:none;"></div>
          <div id="template-footer-region" style="flex-shrink:0;height:0px;overflow:hidden;display:none;position:relative;">
            <iframe id="template-footer-iframe" style="width:100%;height:100%;border:none;pointer-events:none;" sandbox="" scrolling="no"></iframe>
            <div style="position:absolute;inset:0;background:rgba(0,0,0,0.03);pointer-events:none;"></div>
          </div>
        </div>

        <%!-- Blocks panel --%>
        <div id={"#{@id}-right-panel"} class="bg-base-200 text-base-content border-l border-base-300" style="width:220px;min-width:220px;display:flex;flex-direction:column;">
          <div class="border-b border-base-300 text-base-content/70" style="padding:8px 12px;font-size:12px;font-weight:600;">
            Document Elements
          </div>
          <div id={"#{@id}-blocks-panel"} style="flex:1;overflow-y:auto;"></div>
        </div>
      </div>
    </div>

    <style>
      .gjs-off-prv { background-color: oklch(var(--color-base-200)) !important; color: oklch(var(--color-base-content)) !important; }
      <%= "##{@id}-grapesjs" %> { --gjs-left-width: 0px; }
      <%= "##{@id}-grapesjs" %> .gjs-cv-canvas { top: 0 !important; }
      <%= "##{@id}-right-panel" %> { position: sticky; top: 7rem; align-self: flex-start; max-height: calc(100vh - 7rem); overflow-y: auto; }
    </style>
    """
  end
end
