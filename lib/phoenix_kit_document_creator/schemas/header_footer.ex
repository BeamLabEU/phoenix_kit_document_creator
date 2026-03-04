defmodule PhoenixKitDocumentCreator.Schemas.HeaderFooter do
  @moduledoc """
  Schema for reusable header/footer designs.

  Each header/footer stores GrapesJS project data (`*_native`) for round-trip
  editing, plus the rendered HTML/CSS for PDF generation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_doc_headers_footers" do
    field(:name, :string)

    field(:header_html, :string, default: "")
    field(:header_css, :string, default: "")
    field(:header_native, :map)
    field(:footer_html, :string, default: "")
    field(:footer_css, :string, default: "")
    field(:footer_native, :map)

    field(:header_height, :string, default: "25mm")
    field(:footer_height, :string, default: "20mm")

    field(:data, :map, default: %{})
    field(:created_by_uuid, Ecto.UUID)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [
    :header_html,
    :header_css,
    :header_native,
    :footer_html,
    :footer_css,
    :footer_native,
    :header_height,
    :footer_height,
    :data,
    :created_by_uuid
  ]

  def changeset(header_footer, attrs) do
    header_footer
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:header_height, max: 20)
    |> validate_length(:footer_height, max: 20)
  end
end
