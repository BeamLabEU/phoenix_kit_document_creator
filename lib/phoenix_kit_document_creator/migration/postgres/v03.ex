defmodule PhoenixKitDocumentCreator.Migration.Postgres.V03 do
  @moduledoc """
  V03: Add thumbnail column to documents table.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    alter table(:phoenix_kit_doc_templates, prefix: prefix) do
      add_if_not_exists(:thumbnail, :text)
    end

    alter table(:phoenix_kit_doc_documents, prefix: prefix) do
      add_if_not_exists(:thumbnail, :text)
    end
  end

  def down(%{prefix: prefix} = _opts) do
    alter table(:phoenix_kit_doc_templates, prefix: prefix) do
      remove_if_exists(:thumbnail, :text)
    end

    alter table(:phoenix_kit_doc_documents, prefix: prefix) do
      remove_if_exists(:thumbnail, :text)
    end
  end
end
