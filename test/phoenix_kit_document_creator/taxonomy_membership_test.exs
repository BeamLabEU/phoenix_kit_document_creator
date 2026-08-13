defmodule PhoenixKitDocumentCreator.TaxonomyMembershipTest do
  @moduledoc """
  Covers the many-to-many template ↔ (category, group) membership API:
  replace-all writes, the legacy primary-FK mirror, and category listing
  through the join.
  """
  use PhoenixKitDocumentCreator.DataCase, async: true

  alias PhoenixKitDocumentCreator.{Documents, Taxonomy}
  alias PhoenixKitDocumentCreator.Schemas.Template
  alias PhoenixKitDocumentCreator.Test.Repo

  setup do
    # Klient is created first, so it gets the lower Category.position and is
    # therefore the "primary" membership the mirror should pick.
    {:ok, klient} = Taxonomy.create_category(%{name: "Klient document"})
    {:ok, tootmine} = Taxonomy.create_category(%{name: "Tootmine"})
    {:ok, g1} = Taxonomy.create_type(%{name: "Tellimus", category_uuid: klient.uuid})
    {:ok, g2} = Taxonomy.create_type(%{name: "Hooldusjuhend", category_uuid: tootmine.uuid})
    {:ok, tmpl} = %Template{} |> Template.changeset(%{name: "T"}) |> Repo.insert()

    %{klient: klient, tootmine: tootmine, g1: g1, g2: g2, tmpl: tmpl}
  end

  test "set_template_memberships creates rows and mirrors the primary FK", ctx do
    {:ok, _} =
      Taxonomy.set_template_memberships(ctx.tmpl.uuid, [
        %{category_uuid: ctx.klient.uuid, type_uuid: ctx.g1.uuid},
        %{category_uuid: ctx.tootmine.uuid, type_uuid: ctx.g2.uuid}
      ])

    assert length(Taxonomy.list_memberships_for_template(ctx.tmpl.uuid)) == 2

    reloaded = Repo.get!(Template, ctx.tmpl.uuid)
    assert reloaded.category_uuid == ctx.klient.uuid
    assert reloaded.type_uuid == ctx.g1.uuid
  end

  test "set_template_memberships replaces all (shrink) and re-mirrors", ctx do
    {:ok, _} =
      Taxonomy.set_template_memberships(ctx.tmpl.uuid, [
        %{category_uuid: ctx.klient.uuid, type_uuid: ctx.g1.uuid},
        %{category_uuid: ctx.tootmine.uuid, type_uuid: ctx.g2.uuid}
      ])

    {:ok, _} =
      Taxonomy.set_template_memberships(ctx.tmpl.uuid, [
        %{category_uuid: ctx.tootmine.uuid, type_uuid: ctx.g2.uuid}
      ])

    assert length(Taxonomy.list_memberships_for_template(ctx.tmpl.uuid)) == 1
    assert Repo.get!(Template, ctx.tmpl.uuid).category_uuid == ctx.tootmine.uuid
  end

  test "set_template_memberships with empty list clears memberships and mirror", ctx do
    {:ok, _} =
      Taxonomy.set_template_memberships(ctx.tmpl.uuid, [
        %{category_uuid: ctx.klient.uuid, type_uuid: ctx.g1.uuid}
      ])

    {:ok, _} = Taxonomy.set_template_memberships(ctx.tmpl.uuid, [])

    assert Taxonomy.list_memberships_for_template(ctx.tmpl.uuid) == []
    reloaded = Repo.get!(Template, ctx.tmpl.uuid)
    assert is_nil(reloaded.category_uuid)
    assert is_nil(reloaded.type_uuid)
  end

  test "Documents.update_template_taxonomy keeps the join table in sync", ctx do
    {:ok, tmpl} =
      %Template{}
      |> Template.changeset(%{name: "Legacy", google_doc_id: "gd-legacy-1"})
      |> Repo.insert()

    {:ok, _} =
      Documents.update_template_taxonomy(tmpl.google_doc_id, %{
        category_uuid: ctx.klient.uuid,
        type_uuid: ctx.g1.uuid
      })

    assert [%{category_uuid: cat, type_uuid: type}] =
             Taxonomy.list_memberships_for_template(tmpl.uuid)

    assert cat == ctx.klient.uuid
    assert type == ctx.g1.uuid

    # Clearing the category clears the membership too — no orphaned join row.
    {:ok, _} =
      Documents.update_template_taxonomy(tmpl.google_doc_id, %{category_uuid: nil, type_uuid: nil})

    assert Taxonomy.list_memberships_for_template(tmpl.uuid) == []
  end

  test "list_templates_for_category returns the template under each of its categories, with that category's group",
       ctx do
    {:ok, _} =
      Taxonomy.set_template_memberships(ctx.tmpl.uuid, [
        %{category_uuid: ctx.klient.uuid, type_uuid: ctx.g1.uuid},
        %{category_uuid: ctx.tootmine.uuid, type_uuid: ctx.g2.uuid}
      ])

    klient_templates = Documents.list_templates_for_category(ctx.klient.uuid)
    tootmine_templates = Documents.list_templates_for_category(ctx.tootmine.uuid)

    klient_row = Enum.find(klient_templates, &(&1.uuid == ctx.tmpl.uuid))
    tootmine_row = Enum.find(tootmine_templates, &(&1.uuid == ctx.tmpl.uuid))

    assert klient_row
    assert tootmine_row
    # Each listing annotates the template with the group of THAT category's
    # membership, so downstream grouping-by-type stays correct per category.
    assert klient_row.type_uuid == ctx.g1.uuid
    assert tootmine_row.type_uuid == ctx.g2.uuid
  end
end
