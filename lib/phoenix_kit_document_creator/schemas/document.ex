defmodule PhoenixKitDocumentCreator.Schemas.Document do
  @moduledoc """
  Schema for documents created from templates or from scratch.

  A document clones content from a template (with variables filled in) and can
  then be independently edited and exported to PDF.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(draft final)

  schema "phoenix_kit_doc_documents" do
    field(:name, :string)

    belongs_to(:template, PhoenixKitDocumentCreator.Schemas.Template,
      foreign_key: :template_uuid,
      references: :uuid,
      type: UUIDv7
    )

    field(:content_html, :string, default: "")
    field(:content_css, :string, default: "")
    field(:content_native, :map)

    field(:variable_values, :map, default: %{})

    belongs_to(:header, PhoenixKitDocumentCreator.Schemas.HeaderFooter,
      foreign_key: :header_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:footer, PhoenixKitDocumentCreator.Schemas.HeaderFooter,
      foreign_key: :footer_uuid,
      references: :uuid,
      type: UUIDv7
    )

    field(:config, :map, default: %{"paper_size" => "a4", "orientation" => "portrait"})
    field(:status, :string, default: "draft")
    field(:data, :map, default: %{})
    field(:created_by_uuid, Ecto.UUID)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [
    :template_uuid,
    :content_html,
    :content_css,
    :content_native,
    :variable_values,
    :header_uuid,
    :footer_uuid,
    :config,
    :status,
    :data,
    :created_by_uuid
  ]

  def changeset(document, attrs) do
    document
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
  end
end
