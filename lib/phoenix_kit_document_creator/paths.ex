defmodule PhoenixKitDocumentCreator.Paths do
  @moduledoc """
  Centralized path helpers for the Document Creator module.

  All navigation paths go through `PhoenixKit.Utils.Routes.path/1`, which
  handles the configurable URL prefix and locale prefix automatically.

  Use these helpers in templates and `redirect/2` calls instead of
  hardcoding paths — if the module's admin path ever changes, only this
  file needs updating.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/document-creator"

  # ── Main ──────────────────────────────────────────────────────────

  def index, do: Routes.path(@base)

  # ── Templates ─────────────────────────────────────────────────────

  def template_new, do: Routes.path("#{@base}/templates/new")
  def template_edit(uuid), do: Routes.path("#{@base}/templates/#{uuid}/edit")

  # ── Documents ─────────────────────────────────────────────────────

  def document_edit(uuid), do: Routes.path("#{@base}/documents/#{uuid}/edit")

  # ── Headers ───────────────────────────────────────────────────────

  def headers, do: Routes.path("#{@base}/headers")
  def header_new, do: Routes.path("#{@base}/headers/new")
  def header_edit(uuid), do: Routes.path("#{@base}/headers/#{uuid}/edit")

  # ── Footers ───────────────────────────────────────────────────────

  def footers, do: Routes.path("#{@base}/footers")
  def footer_new, do: Routes.path("#{@base}/footers/new")
  def footer_edit(uuid), do: Routes.path("#{@base}/footers/#{uuid}/edit")

  # ── Testing (behind :testing_editors config) ─────────────────────

  def testing, do: Routes.path("#{@base}/testing")
  def testing_pdfme, do: Routes.path("#{@base}/testing/pdfme")
  def testing_tiptap, do: Routes.path("#{@base}/testing/tiptap")
end
