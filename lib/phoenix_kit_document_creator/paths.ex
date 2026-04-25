defmodule PhoenixKitDocumentCreator.Paths do
  @moduledoc """
  Centralized path helpers for the Document Creator module.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/document-creator"

  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @spec templates() :: String.t()
  def templates, do: Routes.path("#{@base}/templates")

  @spec documents() :: String.t()
  def documents, do: Routes.path("#{@base}/documents")

  @spec settings() :: String.t()
  def settings, do: Routes.path("/admin/settings/document-creator")
end
