defmodule PhoenixKitDocumentCreator.Schemas.Document do
  @moduledoc """
  Schema for documents created from templates or from scratch.

  A document clones content from a template (with variables filled in) and can
  then be independently edited and exported to PDF.

  Header/footer content is baked directly into the document via the
  `header_html`, `header_css`, `header_height`, `footer_html`, `footer_css`,
  and `footer_height` fields. These are populated at creation time by
  `Documents.create_document_from_template/3` and make each document fully
  self-contained — no FK references to the headers_footers table are needed.
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
