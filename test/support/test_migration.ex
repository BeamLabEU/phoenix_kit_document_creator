defmodule PhoenixKitDocumentCreator.Test.Migration do
  @moduledoc """
  Test-only migration that creates Document Creator tables and the
  minimum slice of `phoenix_kit` core's schema that the test suite
  reads:

  - `uuid_generate_v7()` PL/pgSQL function (normally provided by core's
    V40). Already created in `test_helper.exs` before this migration
    runs; we don't redefine it here to keep the migration idempotent.
  - `phoenix_kit_settings` — needed by `enabled?/0` and any test that
    reads/writes settings directly. Column shape MUST match
    `PhoenixKit.Settings.Setting` (uuid / key / value / value_json /
    module / date_added / date_updated) — a column mismatch poisons
    the sandbox transaction with `column "module" does not exist`,
    aborting every subsequent query in the same test.
  - `phoenix_kit_activities` — required for activity-log assertions.
    Without this table every `log_activity/1` call from `Documents`
    spams the test output with `relation "phoenix_kit_activities"
    does not exist` warnings (the helper guards with rescue but the
    log noise hides real failures).

  Production migrations live in PhoenixKit core (V86 + V94 for the
  module's own tables; V40 / V94 / V90 for settings + activities).
  """

  use Ecto.Migration

  def up do
    create_if_not_exists table(:phoenix_kit_settings, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:key, :string, null: false, size: 255)
      add(:value, :string)
      add(:value_json, :map)
      add(:module, :string, size: 50)
      add(:date_added, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:date_updated, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create_if_not_exists(unique_index(:phoenix_kit_settings, [:key]))

    create_if_not_exists table(:phoenix_kit_activities, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:action, :string, null: false, size: 100)
      add(:module, :string, size: 50)
      add(:mode, :string, size: 20)
      add(:actor_uuid, :binary_id)
      add(:resource_type, :string, size: 50)
      add(:resource_uuid, :binary_id)
      add(:target_uuid, :binary_id)
      add(:metadata, :map, default: %{})
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(index(:phoenix_kit_activities, [:module]))
    create_if_not_exists(index(:phoenix_kit_activities, [:action]))
    create_if_not_exists(index(:phoenix_kit_activities, [:actor_uuid]))
    create_if_not_exists(index(:phoenix_kit_activities, [:inserted_at]))

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
    drop_if_exists(table(:phoenix_kit_activities))
    drop_if_exists(table(:phoenix_kit_settings))
  end
end
