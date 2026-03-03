defmodule PhoenixKitDocForge do
  @moduledoc """
  Document Creator module for PhoenixKit.

  Compare five PDF generation approaches side-by-side:

  1. **ChromicPDF** — HTML → headless Chrome → PDF (community standard)
  2. **Typst** — markup → Rust NIF → PDF (fast, professional typesetting)
  3. **PDF** — pure Elixir, coordinate-based (most mature, 222K downloads)
  4. **PrawnEx** — pure Elixir, Prawn-inspired (tables, charts, zero deps)
  5. **Mudbrick** — pure Elixir, PDF 2.0 (OpenType fonts, vector paths)

  ## Installation

  Add to your parent app's `mix.exs`:

      {:phoenix_kit_doc_forge, path: "../phoenix_kit_doc_forge"}

  Then `mix deps.get`. The module auto-discovers via beam scanning.
  Enable it in Admin > Modules.

  ## Prerequisites

  - **ChromicPDF**: Requires Chrome or Chromium installed on the system
  - **Typst**: Uses precompiled Rust NIFs — no toolchain needed
  - **PDF, PrawnEx, Mudbrick**: Pure Elixir — zero external dependencies
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

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
      description:
        "Document creation and PDF generation — compare editors and PDF approaches side-by-side"
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
        live_view: {PhoenixKitDocForge.Web.OverviewLive, :index}
      },
      %Tab{
        id: :admin_document_creator_chromic,
        label: "ChromicPDF",
        icon: "hero-globe-alt",
        path: "document-creator/chromic",
        priority: 651,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.ChromicTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_typst,
        label: "Typst",
        icon: "hero-document-arrow-down",
        path: "document-creator/typst",
        priority: 652,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.TypstTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_pdf,
        label: "PDF (Elixir)",
        icon: "hero-code-bracket",
        path: "document-creator/pdf-elixir",
        priority: 653,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.PdfTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_prawn,
        label: "PrawnEx",
        icon: "hero-table-cells",
        path: "document-creator/prawn-ex",
        priority: 654,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.PrawnTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_mudbrick,
        label: "Mudbrick",
        icon: "hero-paint-brush",
        path: "document-creator/mudbrick",
        priority: 655,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.MudbrickTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_builder,
        label: "Template Builder",
        icon: "hero-puzzle-piece",
        path: "document-creator/template-builder",
        priority: 656,
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
        priority: 657,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.TemplatePreviewLive, :index}
      },
      # --- Editor test pages ---
      %Tab{
        id: :admin_document_creator_editors,
        label: "Editors",
        icon: "hero-pencil-square",
        path: "document-creator/editors",
        priority: 660,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.EditorsOverviewLive, :index}
      },
      %Tab{
        id: :admin_document_creator_editor_tiptap,
        label: "TipTap",
        icon: "hero-cursor-arrow-rays",
        path: "document-creator/editors/tiptap",
        priority: 661,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.EditorTiptapTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_editor_quill,
        label: "Quill",
        icon: "hero-pencil",
        path: "document-creator/editors/quill",
        priority: 662,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.EditorQuillTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_editor_ckeditor,
        label: "CKEditor",
        icon: "hero-document-text",
        path: "document-creator/editors/ckeditor",
        priority: 663,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.EditorCkeditorTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_editor_lexical,
        label: "Lexical",
        icon: "hero-code-bracket-square",
        path: "document-creator/editors/lexical",
        priority: 664,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.EditorLexicalTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_editor_grapesjs,
        label: "GrapesJS",
        icon: "hero-squares-2x2",
        path: "document-creator/editors/grapesjs",
        priority: 665,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.EditorGrapesjsTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_editor_jodit,
        label: "Jodit",
        icon: "hero-bold",
        path: "document-creator/editors/jodit",
        priority: 666,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.EditorJoditTestLive, :index}
      },
      %Tab{
        id: :admin_document_creator_editor_pdfme,
        label: "pdfme",
        icon: "hero-document",
        path: "document-creator/editors/pdfme",
        priority: 667,
        level: :admin,
        permission: module_key(),
        parent: :admin_document_creator,
        live_view: {PhoenixKitDocForge.Web.EditorPdfmeTestLive, :index}
      }
    ]
  end

  # ===========================================================================
  # Helper functions
  # ===========================================================================

  @doc "Check if the ChromicPDF library is available."
  def chromic_pdf_available? do
    Code.ensure_loaded?(ChromicPDF)
  end

  @doc "Check if the Typst NIF is available."
  def typst_available? do
    Code.ensure_loaded?(Typst)
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
