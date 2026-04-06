defmodule PhoenixKitDocumentCreator do
  @moduledoc """
  Document Creator module for PhoenixKit.

  Document template design and PDF generation via Google Docs API.

  Templates, documents, and headers/footers are created and edited as
  Google Docs, embedded in the admin UI via iframe. Variables use
  `{{ placeholder }}` syntax and are substituted via the Google Docs
  `replaceAllText` API. PDF export uses the Google Drive export endpoint.

  ## Installation

  Add to your parent app's `mix.exs`:

      {:phoenix_kit_document_creator, path: "../phoenix_kit_document_creator"}

  Then `mix deps.get`. The module auto-discovers via beam scanning.
  Enable it in Admin > Modules.

  ## Google Docs Setup

  Configure the Google Docs integration in Admin > Settings > Document Creator.
  You need a Google Cloud project with Docs API and Drive API enabled,
  and an OAuth 2.0 Client ID (Web application type).
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
  def version, do: "0.2.3"

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
  def css_sources, do: [:phoenix_kit_document_creator]

  @impl PhoenixKit.Module
  def required_integrations, do: ["google"]

  @impl PhoenixKit.Module
  def children, do: []

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      %Tab{
        id: :admin_settings_document_creator,
        label: "Document Creator",
        icon: "hero-document-text",
        path: "document-creator",
        priority: 930,
        level: :admin,
        parent: :admin_settings,
        permission: module_key(),
        match: :exact,
        live_view: {PhoenixKitDocumentCreator.Web.GoogleOAuthSettingsLive, :index}
      }
    ]
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    base_tabs()
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
      }
    ]
  end
end
