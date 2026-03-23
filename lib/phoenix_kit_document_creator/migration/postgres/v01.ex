defmodule PhoenixKitDocumentCreator.Migration.Postgres.V01 do
  @moduledoc """
  V01: Initial Document Creator tables.

  Creates:
  - `phoenix_kit_doc_headers_footers` — combined header/footer records
  - `phoenix_kit_doc_templates` — document templates with editor content
  - `phoenix_kit_doc_documents` — documents created from templates
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    # ── Headers & Footers (created first — referenced by FK) ──────────
    create_if_not_exists table(:phoenix_kit_doc_headers_footers,
                            primary_key: false,
                            prefix: prefix) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)

      add(:header_html, :text, default: "")
      add(:header_css, :text, default: "")
      add(:header_native, :map)
      add(:footer_html, :text, default: "")
      add(:footer_css, :text, default: "")
      add(:footer_native, :map)
      add(:header_height, :string, default: "25mm", size: 20)
      add(:footer_height, :string, default: "20mm", size: 20)

      add(:data, :map, default: %{})
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    # ── Templates ─────────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_doc_templates,
                            primary_key: false,
                            prefix: prefix) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:slug, :string, size: 255)
      add(:description, :text)
      add(:status, :string, default: "draft", size: 20)

      add(:content_html, :text, default: "")
      add(:content_css, :text, default: "")
      add(:content_native, :map)

      add(:variables, :map, default: fragment("'[]'::jsonb"))

      add(
        :header_footer_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:config, :map, default: %{paper_size: "a4", orientation: "portrait"})
      add(:data, :map, default: %{})
      add(:thumbnail, :text)
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(unique_index(:phoenix_kit_doc_templates, [:slug], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_doc_templates, [:status], prefix: prefix))

    # ── Documents ─────────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_doc_documents,
                            primary_key: false,
                            prefix: prefix) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)

      add(
        :template_uuid,
        references(:phoenix_kit_doc_templates,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:content_html, :text, default: "")
      add(:content_css, :text, default: "")
      add(:content_native, :map)

      add(:variable_values, :map, default: %{})

      add(
        :header_footer_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:config, :map, default: %{paper_size: "a4", orientation: "portrait"})
      add(:status, :string, default: "draft", size: 20)
      add(:data, :map, default: %{})
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_doc_documents, [:status], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_doc_documents, [:template_uuid], prefix: prefix))
  end

  def down(%{prefix: prefix} = _opts) do
    drop_if_exists(table(:phoenix_kit_doc_documents, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_doc_templates, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_doc_headers_footers, prefix: prefix))
  end
end
