defmodule PhoenixKitDocumentCreator.Migration.Postgres.V04 do
  @moduledoc """
  V04: Bake header/footer content into documents.

  Documents previously stored foreign keys to the headers_footers table,
  meaning deleting a header/footer could break existing documents.
  This migration copies the header/footer HTML, CSS, and height directly
  into the documents table, then removes the FK references.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    # Add baked header/footer columns
    alter table(:phoenix_kit_doc_documents, prefix: prefix) do
      add_if_not_exists(:header_html, :text, default: "")
      add_if_not_exists(:header_css, :text, default: "")
      add_if_not_exists(:header_height, :string, default: "25mm", size: 20)
      add_if_not_exists(:footer_html, :text, default: "")
      add_if_not_exists(:footer_css, :text, default: "")
      add_if_not_exists(:footer_height, :string, default: "20mm", size: 20)
    end

    flush()

    # Copy header/footer content from referenced records into document rows
    execute("""
    UPDATE #{p}phoenix_kit_doc_documents d
    SET header_html = COALESCE(h.html, ''),
        header_css = COALESCE(h.css, ''),
        header_height = COALESCE(h.height, '25mm')
    FROM #{p}phoenix_kit_doc_headers_footers h
    WHERE d.header_uuid = h.uuid
    """)

    execute("""
    UPDATE #{p}phoenix_kit_doc_documents d
    SET footer_html = COALESCE(f.html, ''),
        footer_css = COALESCE(f.css, ''),
        footer_height = COALESCE(f.height, '20mm')
    FROM #{p}phoenix_kit_doc_headers_footers f
    WHERE d.footer_uuid = f.uuid
    """)

    # Drop the FK constraints and columns
    alter table(:phoenix_kit_doc_documents, prefix: prefix) do
      remove_if_exists(:header_uuid, :uuid)
      remove_if_exists(:footer_uuid, :uuid)
    end
  end

  def down(%{prefix: prefix} = _opts) do
    # Restore FK columns (data is lost — can't reverse the bake)
    alter table(:phoenix_kit_doc_documents, prefix: prefix) do
      add_if_not_exists(
        :header_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add_if_not_exists(
        :footer_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )
    end

    # Remove baked columns
    alter table(:phoenix_kit_doc_documents, prefix: prefix) do
      remove_if_exists(:header_html, :text)
      remove_if_exists(:header_css, :text)
      remove_if_exists(:header_height, :string)
      remove_if_exists(:footer_html, :text)
      remove_if_exists(:footer_css, :text)
      remove_if_exists(:footer_height, :string)
    end
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
