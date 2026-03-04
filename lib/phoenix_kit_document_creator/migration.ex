defmodule PhoenixKitDocumentCreator.Migration do
  @moduledoc """
  Database migration for the Document Creator module.

  ## Usage

  Create a migration in your parent app:

      defmodule MyApp.Repo.Migrations.AddDocumentCreatorTables do
        use Ecto.Migration
        def up, do: PhoenixKitDocumentCreator.Migration.up()
        def down, do: PhoenixKitDocumentCreator.Migration.down()
      end
  """
  use Ecto.Migration

  def up do
    # ── Headers & Footers (created first — referenced by FK) ──────────
    create_if_not_exists table(:phoenix_kit_doc_headers_footers, primary_key: false) do
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
    create_if_not_exists table(:phoenix_kit_doc_templates, primary_key: false) do
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

    # ── Documents ─────────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_doc_documents, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)

      add(
        :template_uuid,
        references(:phoenix_kit_doc_templates,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all
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
          on_delete: :nilify_all
        )
      )

      add(:config, :map, default: %{paper_size: "a4", orientation: "portrait"})
      add(:status, :string, default: "draft", size: 20)
      add(:data, :map, default: %{})
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_doc_documents, [:status]))
    create_if_not_exists(index(:phoenix_kit_doc_documents, [:template_uuid]))
  end

  def down do
    drop_if_exists(table(:phoenix_kit_doc_documents))
    drop_if_exists(table(:phoenix_kit_doc_templates))
    drop_if_exists(table(:phoenix_kit_doc_headers_footers))
  end
end
