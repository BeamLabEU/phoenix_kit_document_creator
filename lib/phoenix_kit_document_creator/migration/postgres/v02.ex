defmodule PhoenixKitDocumentCreator.Migration.Postgres.V02 do
  @moduledoc """
  V02: Split headers and footers into independent entities.

  Changes the combined header/footer record (with paired `header_html`/`footer_html`
  fields) into a single-type record with a `type` discriminator column. Templates
  and documents get separate `header_uuid` and `footer_uuid` foreign keys instead
  of a single `header_footer_uuid`.

  All operations are idempotent — safe to run on databases that were created
  after this change was made (V01 already has the old schema, V02 transforms it).
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    # ── Alter headers_footers: add type + simplified fields ───────────
    alter table(:phoenix_kit_doc_headers_footers, prefix: prefix) do
      add_if_not_exists(:type, :string, null: false, default: "header", size: 20)
      add_if_not_exists(:html, :text, default: "")
      add_if_not_exists(:css, :text, default: "")
      add_if_not_exists(:native, :map)
      add_if_not_exists(:height, :string, default: "25mm", size: 20)
    end

    create_if_not_exists(
      index(:phoenix_kit_doc_headers_footers, [:type], prefix: prefix)
    )

    # Copy existing header data into new fields (no-op if old columns don't exist)
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{p}' AND table_name = 'phoenix_kit_doc_headers_footers'
        AND column_name = 'header_html'
      ) THEN
        UPDATE #{p}phoenix_kit_doc_headers_footers
        SET html = COALESCE(header_html, ''),
            css = COALESCE(header_css, ''),
            native = header_native,
            height = COALESCE(header_height, '25mm'),
            type = 'header';
      END IF;
    END $$;
    """)

    # Remove old paired columns
    alter table(:phoenix_kit_doc_headers_footers, prefix: prefix) do
      remove_if_exists(:header_html, :text)
      remove_if_exists(:header_css, :text)
      remove_if_exists(:header_native, :map)
      remove_if_exists(:footer_html, :text)
      remove_if_exists(:footer_css, :text)
      remove_if_exists(:footer_native, :map)
      remove_if_exists(:header_height, :string)
      remove_if_exists(:footer_height, :string)
    end

    # ── Templates: replace header_footer_uuid with header_uuid + footer_uuid ──
    alter table(:phoenix_kit_doc_templates, prefix: prefix) do
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

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{p}' AND table_name = 'phoenix_kit_doc_templates'
        AND column_name = 'header_footer_uuid'
      ) THEN
        UPDATE #{p}phoenix_kit_doc_templates
        SET header_uuid = header_footer_uuid
        WHERE header_footer_uuid IS NOT NULL;
      END IF;
    END $$;
    """)

    alter table(:phoenix_kit_doc_templates, prefix: prefix) do
      remove_if_exists(:header_footer_uuid, :uuid)
    end

    # ── Documents: same replacement ───────────────────────────────────
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

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{p}' AND table_name = 'phoenix_kit_doc_documents'
        AND column_name = 'header_footer_uuid'
      ) THEN
        UPDATE #{p}phoenix_kit_doc_documents
        SET header_uuid = header_footer_uuid
        WHERE header_footer_uuid IS NOT NULL;
      END IF;
    END $$;
    """)

    alter table(:phoenix_kit_doc_documents, prefix: prefix) do
      remove_if_exists(:header_footer_uuid, :uuid)
    end
  end

  def down(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    # Restore old columns on headers_footers
    alter table(:phoenix_kit_doc_headers_footers, prefix: prefix) do
      add_if_not_exists(:header_html, :text, default: "")
      add_if_not_exists(:header_css, :text, default: "")
      add_if_not_exists(:header_native, :map)
      add_if_not_exists(:footer_html, :text, default: "")
      add_if_not_exists(:footer_css, :text, default: "")
      add_if_not_exists(:footer_native, :map)
      add_if_not_exists(:header_height, :string, default: "25mm", size: 20)
      add_if_not_exists(:footer_height, :string, default: "20mm", size: 20)
    end

    execute("""
    UPDATE #{p}phoenix_kit_doc_headers_footers
    SET header_html = COALESCE(html, ''),
        header_css = COALESCE(css, ''),
        header_native = native,
        header_height = COALESCE(height, '25mm')
    """)

    alter table(:phoenix_kit_doc_headers_footers, prefix: prefix) do
      remove_if_exists(:type, :string)
      remove_if_exists(:html, :text)
      remove_if_exists(:css, :text)
      remove_if_exists(:native, :map)
      remove_if_exists(:height, :string)
    end

    # Restore header_footer_uuid on templates
    alter table(:phoenix_kit_doc_templates, prefix: prefix) do
      add_if_not_exists(
        :header_footer_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )
    end

    execute("""
    UPDATE #{p}phoenix_kit_doc_templates
    SET header_footer_uuid = header_uuid
    WHERE header_uuid IS NOT NULL
    """)

    alter table(:phoenix_kit_doc_templates, prefix: prefix) do
      remove_if_exists(:header_uuid, :uuid)
      remove_if_exists(:footer_uuid, :uuid)
    end

    # Restore header_footer_uuid on documents
    alter table(:phoenix_kit_doc_documents, prefix: prefix) do
      add_if_not_exists(
        :header_footer_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )
    end

    execute("""
    UPDATE #{p}phoenix_kit_doc_documents
    SET header_footer_uuid = header_uuid
    WHERE header_uuid IS NOT NULL
    """)

    alter table(:phoenix_kit_doc_documents, prefix: prefix) do
      remove_if_exists(:header_uuid, :uuid)
      remove_if_exists(:footer_uuid, :uuid)
    end
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
