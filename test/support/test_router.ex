defmodule PhoenixKitDocumentCreator.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitDocumentCreator.Paths` so `live/2` calls in
  tests work with exactly the same URLs the LiveViews push themselves
  to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  `phoenix_kit_settings` table is unavailable, and admin paths always
  get the default locale ("en") prefix — so our base becomes
  `/en/admin/document-creator`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitDocumentCreator.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/document-creator", PhoenixKitDocumentCreator.Web do
    pipe_through(:browser)

    live_session :doc_creator_test,
      layout: {PhoenixKitDocumentCreator.Test.Layouts, :app},
      on_mount: {PhoenixKitDocumentCreator.Test.Hooks, :assign_scope} do
      live("/", DocumentsLive, :documents)
      live("/templates", DocumentsLive, :templates)
    end
  end

  scope "/en/admin/settings/document-creator", PhoenixKitDocumentCreator.Web do
    pipe_through(:browser)

    live_session :doc_creator_settings_test,
      layout: {PhoenixKitDocumentCreator.Test.Layouts, :app},
      on_mount: {PhoenixKitDocumentCreator.Test.Hooks, :assign_scope} do
      live("/", GoogleOAuthSettingsLive, :index)
    end
  end
end
