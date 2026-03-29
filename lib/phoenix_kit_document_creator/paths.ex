defmodule PhoenixKitDocumentCreator.Paths do
  @moduledoc """
  Centralized path helpers for the Document Creator module.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/document-creator"

  def index, do: Routes.path(@base)
  def templates, do: Routes.path("#{@base}/templates")
  def documents, do: Routes.path("#{@base}/documents")
  def settings, do: Routes.path("/admin/settings/document-creator")
end
