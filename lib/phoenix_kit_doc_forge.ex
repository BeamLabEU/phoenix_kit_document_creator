defmodule PhoenixKitDocForge do
  @moduledoc """
  Document Creator module for PhoenixKit.

  Visual template design with GrapesJS (drag-and-drop page builder) and
  PDF generation via ChromicPDF (headless Chrome).

  ## Installation

  Add to your parent app's `mix.exs`:

      {:phoenix_kit_doc_forge, path: "../phoenix_kit_doc_forge"}

  Then `mix deps.get`. The module auto-discovers via beam scanning.
  Enable it in Admin > Modules.

  ## Testing Editors

  Alternative editors (pdfme, TipTap) are available behind a config flag:

      config :phoenix_kit_doc_forge, :testing_editors, true

  These load from CDN — no extra mix dependencies.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  @testing_editors Application.compile_env(:phoenix_kit_doc_forge, :testing_editors, false)

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
  def version, do: "0.1.0"

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
  def children do
    if chromic_pdf_available?() do
      [{PhoenixKitDocForge.ChromeSupervisor, []}]
    else
      []
    end
  end

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
        live_view: {PhoenixKitDocForge.Web.EditorGrapesjsTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_builder,
        label: "Template Builder",
        icon: "hero-puzzle-piece",
        path: "document-creator/template-builder",
        priority: 651,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.TemplateBuilderLive, :index}
      },
      %Tab{
        id: :admin_document_creator_preview,
        label: "Template Preview",
        icon: "hero-eye",
        path: "document-creator/template-preview",
        priority: 652,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.TemplatePreviewLive, :index}
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
          live_view: {PhoenixKitDocForge.Web.TestingLive, :index}
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
          live_view: {PhoenixKitDocForge.Web.EditorPdfmeTestLive, :index}
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
          live_view: {PhoenixKitDocForge.Web.EditorTiptapTestLive, :index}
        }
      ]
    else
      []
    end
  end

  # ===========================================================================
  # Helper functions
  # ===========================================================================

  @doc "Check if the ChromicPDF library is available."
  def chromic_pdf_available? do
    Code.ensure_loaded?(ChromicPDF)
  end

  @doc "Check if Chrome or Chromium is installed on the system."
  def chrome_installed? do
    path_check =
      Enum.any?(
        ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"],
        fn cmd ->
          System.find_executable(cmd) != nil
        end
      )

    path_check or macos_chrome_installed?()
  end

  defp macos_chrome_installed? do
    Enum.any?(
      [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium"
      ],
      &File.exists?/1
    )
  end
end
