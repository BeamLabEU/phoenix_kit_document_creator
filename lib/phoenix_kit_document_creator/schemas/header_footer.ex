defmodule PhoenixKitDocumentCreator.Schemas.HeaderFooter do
  @moduledoc """
  Schema for reusable header or footer designs.

  Each record is either a `"header"` or `"footer"` (determined by the `type` field).
  Stores GrapesJS project data (`native`) for round-trip editing, plus rendered
  HTML/CSS for PDF generation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @types ~w(header footer)

  schema "phoenix_kit_doc_headers_footers" do
    field(:name, :string)
    field(:type, :string)

    field(:html, :string, default: "")
    field(:css, :string, default: "")
    field(:native, :map)
    field(:height, :string, default: "25mm")

    field(:data, :map, default: %{})
    field(:created_by_uuid, Ecto.UUID)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name, :type]
  @optional_fields [
    :html,
    :css,
    :native,
    :height,
    :data,
    :created_by_uuid
  ]

  def changeset(header_footer, attrs) do
    header_footer
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:type, @types)
    |> validate_length(:height, max: 20)
  end
end
