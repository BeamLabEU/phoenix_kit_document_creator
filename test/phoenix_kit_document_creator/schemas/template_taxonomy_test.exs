defmodule PhoenixKitDocumentCreator.Schemas.TemplateTaxonomyTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Schemas.TemplateTaxonomy

  test "valid changeset with template_uuid and category_uuid" do
    attrs = %{template_uuid: Ecto.UUID.generate(), category_uuid: Ecto.UUID.generate()}
    cs = TemplateTaxonomy.changeset(%TemplateTaxonomy{}, attrs)
    assert cs.valid?
  end

  test "template_uuid and category_uuid are required" do
    cs = TemplateTaxonomy.changeset(%TemplateTaxonomy{}, %{})
    refute cs.valid?
    assert %{template_uuid: _, category_uuid: _} = errors_on(cs)
  end

  test "type_uuid is optional (a category membership with no group)" do
    attrs = %{
      template_uuid: Ecto.UUID.generate(),
      category_uuid: Ecto.UUID.generate(),
      type_uuid: nil
    }

    assert TemplateTaxonomy.changeset(%TemplateTaxonomy{}, attrs).valid?
  end

  defp errors_on(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
  end
end
