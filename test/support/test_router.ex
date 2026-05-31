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
      # `Paths.documents()` resolves to `.../document-creator/documents`, which is
      # where the LiveView push_patches itself on sort/filter/pagination/view
      # changes. Register it (alongside the bare base) so those patches resolve
      # in tests and event → URL → handle_params round-trips can be asserted.
      live("/documents", DocumentsLive, :documents)
      live("/templates", DocumentsLive, :templates)
      live("/categories", CategoriesLive, :index)
      live("/categories/new", CategoryFormLive, :new)
      live("/categories/:uuid/edit", CategoryFormLive, :edit)
      live("/categories/:category_uuid/types/new", TypeFormLive, :new)
    end
  end

  scope "/en/admin/document-creator", PhoenixKitDocumentCreator.Web do
    pipe_through(:browser)

    live_session :doc_creator_types_test,
      layout: {PhoenixKitDocumentCreator.Test.Layouts, :app},
      on_mount: {PhoenixKitDocumentCreator.Test.Hooks, :assign_scope} do
      live("/types/:uuid/edit", TypeFormLive, :edit)
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
