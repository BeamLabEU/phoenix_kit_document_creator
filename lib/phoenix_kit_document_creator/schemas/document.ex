defmodule PhoenixKitDocumentCreator.Schemas.Document do
  @moduledoc """
  Schema for documents created from templates or from scratch.

  Documents are now managed as Google Docs in Google Drive. The `google_doc_id`
  field links a document record to its Google Doc. Creating a document from a
  template copies the Google Doc and substitutes `{{ variables }}` via the API.

  Note: Several fields (`content_html`, `content_css`, `content_native`,
  `header_html/css/height`, `footer_html/css/height`) are retained for database
  compatibility but are no longer used in the Google Docs workflow. A future
  migration should remove these columns.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_doc_documents" do
    field(:name, :string)
    field(:google_doc_id, :string)

    belongs_to(:template, PhoenixKitDocumentCreator.Schemas.Template,
      foreign_key: :template_uuid,
      references: :uuid,
      type: UUIDv7
    )

    field(:content_html, :string, default: "")
    field(:content_css, :string, default: "")
    field(:content_native, :map)

    field(:variable_values, :map, default: %{})

    field(:header_html, :string, default: "")
    field(:header_css, :string, default: "")
    field(:header_height, :string, default: "25mm")
    field(:footer_html, :string, default: "")
    field(:footer_css, :string, default: "")
    field(:footer_height, :string, default: "20mm")

    field(:config, :map, default: %{"paper_size" => "a4", "orientation" => "portrait"})
    field(:data, :map, default: %{})
    field(:thumbnail, :string)
    field(:created_by_uuid, Ecto.UUID)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [
    :template_uuid,
    :google_doc_id,
    :content_html,
    :content_css,
    :content_native,
    :variable_values,
    :header_html,
    :header_css,
    :header_height,
    :footer_html,
    :footer_css,
    :footer_height,
    :config,
    :data,
    :thumbnail,
    :created_by_uuid
  ]

  def changeset(document, attrs) do
    document
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
  end
end
