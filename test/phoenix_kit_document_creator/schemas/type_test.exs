defmodule PhoenixKitDocumentCreator.Schemas.TypeTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Schemas.Type

  test "valid changeset with name and category_uuid" do
    cs = Type.changeset(%Type{}, %{name: "Invoice", category_uuid: UUIDv7.generate()})
    assert cs.valid?
  end

  test "name and category_uuid are required" do
    cs = Type.changeset(%Type{}, %{})
    refute cs.valid?
    errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
    assert Map.has_key?(errors, :name)
    assert Map.has_key?(errors, :category_uuid)
  end
end
