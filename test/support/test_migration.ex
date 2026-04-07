defmodule PhoenixKitDocumentCreator.Test.Migration do
  @moduledoc """
  Test-only migration that creates Document Creator tables.
  Production migrations live in PhoenixKit core (V86 + V94).
  """

  use Ecto.Migration

  def up do
    create_if_not_exists table(:phoenix_kit_doc_headers_footers,
                           primary_key: false
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:type, :string, null: false, default: "header", size: 20)
      add(:html, :text, default: "")
      add(:css, :text, default: "")
      add(:native, :map)
      add(:height, :string, default: "25mm", size: 20)
      add(:google_doc_id, :string, size: 255)
      add(:data, :map, default: %{})
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_doc_headers_footers, [:type]))

    create_if_not_exists table(:phoenix_kit_doc_templates,
                           primary_key: false
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:slug, :string, size: 255)
      add(:description, :text)
      add(:status, :string, default: "published", null: false, size: 20)
      add(:google_doc_id, :string, size: 255)
      add(:path, :string, size: 500)
      add(:folder_id, :string, size: 255)
      add(:content_html, :text, default: "")
      add(:content_css, :text, default: "")
      add(:content_native, :map)
      add(:variables, :map, default: fragment("'[]'::jsonb"))

      add(
        :header_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all
        )
      )

      add(
        :footer_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all
        )
      )

      add(:config, :map, default: %{paper_size: "a4", orientation: "portrait"})
      add(:data, :map, default: %{})
      add(:thumbnail, :text)
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(unique_index(:phoenix_kit_doc_templates, [:slug]))
    create_if_not_exists(index(:phoenix_kit_doc_templates, [:status]))

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_doc_templates_google_doc_id_unique_idx
      ON phoenix_kit_doc_templates (google_doc_id)
      WHERE google_doc_id IS NOT NULL
    """)

    create_if_not_exists table(:phoenix_kit_doc_documents,
                           primary_key: false
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:google_doc_id, :string, size: 255)
      add(:path, :string, size: 500)
      add(:folder_id, :string, size: 255)
      add(:status, :string, default: "published", null: false, size: 20)

      add(
        :template_uuid,
        references(:phoenix_kit_doc_templates, column: :uuid, type: :uuid, on_delete: :nilify_all)
      )

      add(:content_html, :text, default: "")
      add(:content_css, :text, default: "")
      add(:content_native, :map)
      add(:variable_values, :map, default: %{})
      add(:header_html, :text, default: "")
      add(:header_css, :text, default: "")
      add(:header_height, :string, default: "25mm", size: 20)
      add(:footer_html, :text, default: "")
      add(:footer_css, :text, default: "")
      add(:footer_height, :string, default: "20mm", size: 20)
      add(:config, :map, default: %{paper_size: "a4", orientation: "portrait"})
      add(:data, :map, default: %{})
      add(:thumbnail, :text)
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_doc_documents, [:template_uuid]))
    create_if_not_exists(index(:phoenix_kit_doc_documents, [:status]))

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_doc_documents_google_doc_id_unique_idx
      ON phoenix_kit_doc_documents (google_doc_id)
      WHERE google_doc_id IS NOT NULL
    """)
  end

  def down do
    drop_if_exists(table(:phoenix_kit_doc_documents))
    drop_if_exists(table(:phoenix_kit_doc_templates))
    drop_if_exists(table(:phoenix_kit_doc_headers_footers))
  end
end
