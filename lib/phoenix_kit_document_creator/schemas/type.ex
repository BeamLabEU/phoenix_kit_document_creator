defmodule PhoenixKitDocumentCreator.Schemas.Type do
  @moduledoc """
  Second-level taxonomy node. Every Type belongs to exactly one
  Category. Soft-deleted via `status = "deleted"`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active deleted)

  schema "phoenix_kit_doc_types" do
    field(:name, :string)
    field(:description, :string)
    field(:position, :integer, default: 0)
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    belongs_to(:category, PhoenixKitDocumentCreator.Schemas.Category,
      foreign_key: :category_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name, :category_uuid]
  @optional_fields [:description, :position, :status, :data]

  @doc "Returns the list of valid status values."
  def statuses, do: @statuses

  def changeset(type, attrs) do
    type
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:category_uuid)
  end
end
