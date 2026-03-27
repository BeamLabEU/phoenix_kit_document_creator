defmodule PhoenixKitDocumentCreator do
  @moduledoc """
  Document Creator module for PhoenixKit.

  Visual template design with GrapesJS (drag-and-drop page builder) and
  PDF generation via Gotenberg (Docker-based HTML-to-PDF API).

  ## Installation

  Add to your parent app's `mix.exs`:

      {:phoenix_kit_document_creator, path: "../phoenix_kit_document_creator"}

  Then `mix deps.get`. The module auto-discovers via beam scanning.
  Enable it in Admin > Modules.

  ## Gotenberg

  PDF generation requires a running Gotenberg instance. Configure the URL:

      config :phoenix_kit_document_creator, :gotenberg_url, "http://gotenberg:3000"

  ## Testing Editors

  Alternative editors (pdfme, TipTap) are available behind a config flag:

      config :phoenix_kit_document_creator, :testing_editors, true

  These load from CDN — no extra mix dependencies.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  @testing_editors Application.compile_env(:phoenix_kit_document_creator, :testing_editors, false)

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def module_key, do: "document_creator"

  @impl PhoenixKit.Module
  def module_name, do: "Document Creator"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("document_creator_enabled", false)
  rescue
    _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module("document_creator_enabled", true, module_key())
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("document_creator_enabled", false, module_key())
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def version, do: "0.1.2"

  # Migrations are handled by PhoenixKit core (V86).
  # @impl PhoenixKit.Module
  # def migration_module, do: nil

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Document Creator",
      icon: "hero-document-text",
      description: "Visual template design and PDF generation"
    }
  end

  @impl PhoenixKit.Module
  def children, do: []

  @impl PhoenixKit.Module
  def admin_tabs do
    base_tabs() ++ testing_tabs()
  end

  defp base_tabs do
    [
      %Tab{
        id: :admin_document_creator,
        label: "Document Creator",
        icon: "hero-document-text",
        path: "document-creator",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true,
        live_view: {PhoenixKitDocumentCreator.Web.DocumentsLive, :documents}
      },
      %Tab{
        id: :admin_document_creator_templates,
        label: "Templates",
        icon: "hero-document-text",
        path: "document-creator/templates",
        priority: 649,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        match: :prefix,
        live_view: {PhoenixKitDocumentCreator.Web.DocumentsLive, :templates}
      },
      %Tab{
        id: :admin_document_creator_documents,
        label: "Documents",
        icon: "hero-document-duplicate",
        path: "document-creator/documents",
        priority: 648,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        match: :prefix,
        live_view: {PhoenixKitDocumentCreator.Web.DocumentsLive, :documents}
      },
      %Tab{
        id: :admin_document_creator_template_new,
        label: "New Template",
        icon: "hero-plus",
        path: "document-creator/templates/new",
        priority: 651,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator_templates,
        visible: false,
        live_view: {PhoenixKitDocumentCreator.Web.TemplateEditorLive, :new}
      },
      %Tab{
        id: :admin_document_creator_template_edit,
        label: "Edit Template",
        icon: "hero-pencil-square",
        path: "document-creator/templates/:uuid/edit",
        priority: 652,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator_templates,
        visible: false,
        live_view: {PhoenixKitDocumentCreator.Web.TemplateEditorLive, :edit}
      },
      %Tab{
        id: :admin_document_creator_document_edit,
        label: "Edit Document",
        icon: "hero-pencil-square",
        path: "document-creator/documents/:uuid/edit",
        priority: 653,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator_documents,
        visible: false,
        live_view: {PhoenixKitDocumentCreator.Web.DocumentEditorLive, :edit}
      },
      %Tab{
        id: :admin_document_creator_headers,
        label: "Headers",
        icon: "hero-document-arrow-up",
        path: "document-creator/headers",
        priority: 660,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocumentCreator.Web.HeaderFooterLive, :headers}
      },
      %Tab{
        id: :admin_document_creator_header_new,
        label: "New Header",
        icon: "hero-plus",
        path: "document-creator/headers/new",
        priority: 661,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        visible: false,
        live_view: {PhoenixKitDocumentCreator.Web.HeaderFooterEditorLive, :header_new}
      },
      %Tab{
        id: :admin_document_creator_header_edit,
        label: "Edit Header",
        icon: "hero-pencil-square",
        path: "document-creator/headers/:uuid/edit",
        priority: 662,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        visible: false,
        live_view: {PhoenixKitDocumentCreator.Web.HeaderFooterEditorLive, :header_edit}
      },
      %Tab{
        id: :admin_document_creator_footers,
        label: "Footers",
        icon: "hero-document-arrow-down",
        path: "document-creator/footers",
        priority: 665,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocumentCreator.Web.HeaderFooterLive, :footers}
      },
      %Tab{
        id: :admin_document_creator_footer_new,
        label: "New Footer",
        icon: "hero-plus",
        path: "document-creator/footers/new",
        priority: 666,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        visible: false,
        live_view: {PhoenixKitDocumentCreator.Web.HeaderFooterEditorLive, :footer_new}
      },
      %Tab{
        id: :admin_document_creator_footer_edit,
        label: "Edit Footer",
        icon: "hero-pencil-square",
        path: "document-creator/footers/:uuid/edit",
        priority: 667,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        visible: false,
        live_view: {PhoenixKitDocumentCreator.Web.HeaderFooterEditorLive, :footer_edit}
      }
    ]
  end

  defp testing_tabs do
    if @testing_editors do
      [
        %Tab{
          id: :admin_document_creator_testing,
          label: "Testing",
          icon: "hero-beaker",
          path: "document-creator/testing",
          priority: 690,
          level: :admin,
          permission: module_key(),
          parent: :admin_document_creator,
          live_view: {PhoenixKitDocumentCreator.Web.TestingLive, :index}
        },
        %Tab{
          id: :admin_document_creator_testing_pdfme,
          label: "pdfme",
          icon: "hero-document",
          path: "document-creator/testing/pdfme",
          priority: 691,
          level: :admin,
          permission: module_key(),
          parent: :admin_document_creator,
          live_view: {PhoenixKitDocumentCreator.Web.EditorPdfmeTestLive, :index}
        },
        %Tab{
          id: :admin_document_creator_testing_tiptap,
          label: "TipTap",
          icon: "hero-cursor-arrow-rays",
          path: "document-creator/testing/tiptap",
          priority: 692,
          level: :admin,
          permission: module_key(),
          parent: :admin_document_creator,
          live_view: {PhoenixKitDocumentCreator.Web.EditorTiptapTestLive, :index}
        }
      ]
    else
      []
    end
  end

end
