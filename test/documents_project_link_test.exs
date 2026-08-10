defmodule PhoenixKitDocumentCreator.DocumentsProjectLinkTest do
  @moduledoc """
  V1 of the module-owned migration chain: per-project document linkage —
  the projects hub's Documents tab API.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.Document
  alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo

  defp doc_fixture(attrs \\ %{}) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(
        Map.merge(
          %{
            name: "Doc #{System.unique_integer([:positive])}",
            google_doc_id: "gdoc-#{System.unique_integer([:positive])}",
            status: "published"
          },
          attrs
        )
      )
      |> TestRepo.insert()

    doc
  end

  defp project_fixture do
    uuid = Ecto.UUID.generate()

    TestRepo.query!(
      "INSERT INTO phoenix_kit_projects (uuid, name) VALUES ($1, $2)",
      [Ecto.UUID.dump!(uuid), "Link target"]
    )

    uuid
  end

  test "link / list / unlink round-trip" do
    project_uuid = project_fixture()
    doc = doc_fixture()
    other = doc_fixture()

    assert Documents.list_documents_for_project(project_uuid) == []
    assert Enum.any?(Documents.list_unlinked_documents(), &(&1["uuid"] == doc.uuid))

    assert {:ok, linked} = Documents.set_document_project(doc.uuid, project_uuid)
    assert linked["uuid"] == doc.uuid

    assert [%{"uuid" => listed}] = Documents.list_documents_for_project(project_uuid)
    assert listed == doc.uuid
    refute Enum.any?(Documents.list_unlinked_documents(), &(&1["uuid"] == doc.uuid))
    assert Enum.any?(Documents.list_unlinked_documents(), &(&1["uuid"] == other.uuid))

    assert {:ok, _} = Documents.set_document_project(doc.uuid, nil)
    assert Documents.list_documents_for_project(project_uuid) == []
  end

  test "unknown document uuid errors cleanly" do
    assert {:error, :not_found} =
             Documents.set_document_project(Ecto.UUID.generate(), Ecto.UUID.generate())
  end

  test "a nonexistent project errors as a changeset, not a raise" do
    doc = doc_fixture()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Documents.set_document_project(doc.uuid, Ecto.UUID.generate())

    assert changeset.errors[:project_uuid]
  end

  test "the project-extension contract declares the Documents tab" do
    assert [ext] = PhoenixKitDocumentCreator.phoenix_kit_project_extensions()
    assert ext.key == "document_creator_docs"
    assert ext.module_key == "document_creator"
    refute ext.default_enabled
    assert [%{key: "documents", lv: lv}] = ext.tabs
    assert Code.ensure_loaded?(lv)
  end
end
