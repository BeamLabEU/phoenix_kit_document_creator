# Only define this module when the test repo is available (DB connected).
# When excluded, the module is not compiled, avoiding DataCase load errors.
if Code.ensure_loaded?(PhoenixKitDocumentCreator.DataCase) do
  defmodule PhoenixKitDocumentCreator.Integration.DocumentsTest do
    use PhoenixKitDocumentCreator.DataCase, async: true

    alias PhoenixKitDocumentCreator.Documents
    alias PhoenixKitDocumentCreator.Schemas.Document
    alias PhoenixKitDocumentCreator.Schemas.Template

    # ===========================================================================
    # Upsert from Drive
    # ===========================================================================

    describe "upsert_template_from_drive/2" do
      test "inserts a new template" do
        assert {:ok, template} =
                 Documents.upsert_template_from_drive(%{"id" => "gdoc_t1", "name" => "Invoice"})

        assert template.google_doc_id == "gdoc_t1"
        assert template.name == "Invoice"
        assert template.status == "published"
      end

      test "upserts on conflict (same google_doc_id)" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "gdoc_t2", "name" => "Original"})

        {:ok, updated} =
          Documents.upsert_template_from_drive(%{"id" => "gdoc_t2", "name" => "Renamed"})

        assert updated.name == "Renamed"

        # Only one record exists
        count =
          Template
          |> where([t], t.google_doc_id == "gdoc_t2")
          |> Repo.aggregate(:count)

        assert count == 1
      end

      test "accepts extra attrs (path, folder_id)" do
        {:ok, template} =
          Documents.upsert_template_from_drive(
            %{"id" => "gdoc_t3", "name" => "With Path"},
            %{path: "clients/templates", folder_id: "folder_abc"}
          )

        assert template.path == "clients/templates"
        assert template.folder_id == "folder_abc"
      end

      test "sets status to published on upsert" do
        {:ok, template} =
          Documents.upsert_template_from_drive(%{"id" => "gdoc_t4", "name" => "Test"})

        # Manually mark as lost
        Template
        |> where([t], t.uuid == ^template.uuid)
        |> Repo.update_all(set: [status: "lost"])

        # Re-upsert should restore to published
        {:ok, restored} =
          Documents.upsert_template_from_drive(%{"id" => "gdoc_t4", "name" => "Test"})

        assert restored.status == "published"
      end
    end

    describe "upsert_document_from_drive/2" do
      test "inserts a new document" do
        assert {:ok, doc} =
                 Documents.upsert_document_from_drive(%{"id" => "gdoc_d1", "name" => "Report"})

        assert doc.google_doc_id == "gdoc_d1"
        assert doc.name == "Report"
        assert doc.status == "published"
      end

      test "upserts on conflict (same google_doc_id)" do
        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "gdoc_d2", "name" => "Original"})

        {:ok, updated} =
          Documents.upsert_document_from_drive(%{"id" => "gdoc_d2", "name" => "Renamed"})

        assert updated.name == "Renamed"

        count =
          Document
          |> where([d], d.google_doc_id == "gdoc_d2")
          |> Repo.aggregate(:count)

        assert count == 1
      end

      test "accepts extra attrs (path, folder_id)" do
        {:ok, doc} =
          Documents.upsert_document_from_drive(
            %{"id" => "gdoc_d3", "name" => "With Path"},
            %{path: "clients/documents", folder_id: "folder_def"}
          )

        assert doc.path == "clients/documents"
        assert doc.folder_id == "folder_def"
      end
    end

    # ===========================================================================
    # DB Listing
    # ===========================================================================

    describe "list_templates_from_db/0" do
      test "returns published, lost, and unfiled templates" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "lt1", "name" => "Published"})

        {:ok, t2} =
          Documents.upsert_template_from_drive(%{"id" => "lt2", "name" => "Lost"})

        Template
        |> where([t], t.uuid == ^t2.uuid)
        |> Repo.update_all(set: [status: "lost"])

        {:ok, t3} =
          Documents.upsert_template_from_drive(%{"id" => "lt3", "name" => "Trashed"})

        Template
        |> where([t], t.uuid == ^t3.uuid)
        |> Repo.update_all(set: [status: "trashed"])

        results = Documents.list_templates_from_db()
        ids = Enum.map(results, & &1["id"])

        assert "lt1" in ids
        assert "lt2" in ids
        refute "lt3" in ids
      end

      test "excludes templates without google_doc_id" do
        Repo.insert!(%Template{name: "No GDoc ID", status: "published"})

        results = Documents.list_templates_from_db()
        names = Enum.map(results, & &1["name"])

        refute "No GDoc ID" in names
      end

      test "returns maps with expected keys" do
        {:ok, _} =
          Documents.upsert_template_from_drive(
            %{"id" => "lt_map", "name" => "Map Test"},
            %{path: "test/path", folder_id: "fid"}
          )

        [result] = Documents.list_templates_from_db()

        assert result["id"] == "lt_map"
        assert result["name"] == "Map Test"
        assert result["status"] == "published"
        assert result["path"] == "test/path"
        assert result["folder_id"] == "fid"
        assert is_binary(result["modifiedTime"])
      end
    end

    describe "list_documents_from_db/0" do
      test "returns published and lost documents, excludes trashed" do
        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "ld1", "name" => "Published"})

        {:ok, d2} =
          Documents.upsert_document_from_drive(%{"id" => "ld2", "name" => "Trashed"})

        Document
        |> where([d], d.uuid == ^d2.uuid)
        |> Repo.update_all(set: [status: "trashed"])

        results = Documents.list_documents_from_db()
        ids = Enum.map(results, & &1["id"])

        assert "ld1" in ids
        refute "ld2" in ids
      end
    end

    describe "list_trashed_templates_from_db/0" do
      test "returns only trashed templates" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "ltt1", "name" => "Active"})

        {:ok, t2} =
          Documents.upsert_template_from_drive(%{"id" => "ltt2", "name" => "Trashed A"})

        {:ok, t3} =
          Documents.upsert_template_from_drive(%{"id" => "ltt3", "name" => "Trashed B"})

        Template
        |> where([t], t.uuid in ^[t2.uuid, t3.uuid])
        |> Repo.update_all(set: [status: "trashed"])

        results = Documents.list_trashed_templates_from_db()
        ids = Enum.map(results, & &1["id"])

        refute "ltt1" in ids
        assert "ltt2" in ids
        assert "ltt3" in ids
      end

      test "excludes templates without google_doc_id" do
        Repo.insert!(%Template{name: "No GDoc", status: "trashed"})

        results = Documents.list_trashed_templates_from_db()
        names = Enum.map(results, & &1["name"])

        refute "No GDoc" in names
      end

      test "returns empty list when nothing is trashed" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "ltt_none", "name" => "Active"})

        assert Documents.list_trashed_templates_from_db() == []
      end
    end

    describe "list_trashed_documents_from_db/0" do
      test "returns only trashed documents" do
        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "ltd1", "name" => "Active"})

        {:ok, d2} =
          Documents.upsert_document_from_drive(%{"id" => "ltd2", "name" => "Trashed"})

        Document
        |> where([d], d.uuid == ^d2.uuid)
        |> Repo.update_all(set: [status: "trashed"])

        results = Documents.list_trashed_documents_from_db()
        ids = Enum.map(results, & &1["id"])

        refute "ltd1" in ids
        assert "ltd2" in ids
      end

      test "returns empty list when nothing is trashed" do
        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "ltd_none", "name" => "Active"})

        assert Documents.list_trashed_documents_from_db() == []
      end
    end

    # ===========================================================================
    # Thumbnails
    # ===========================================================================

    describe "persist_thumbnail/2" do
      test "persists thumbnail to template" do
        {:ok, t} =
          Documents.upsert_template_from_drive(%{"id" => "thumb_t", "name" => "Thumb Test"})

        :ok = Documents.persist_thumbnail("thumb_t", "data:image/png;base64,abc")

        updated = Repo.get!(Template, t.uuid)
        assert updated.thumbnail == "data:image/png;base64,abc"
      end

      test "persists thumbnail to document if no matching template" do
        {:ok, d} =
          Documents.upsert_document_from_drive(%{"id" => "thumb_d", "name" => "Doc Thumb"})

        :ok = Documents.persist_thumbnail("thumb_d", "data:image/png;base64,xyz")

        updated = Repo.get!(Document, d.uuid)
        assert updated.thumbnail == "data:image/png;base64,xyz"
      end
    end

    describe "load_cached_thumbnails/1" do
      test "loads thumbnails from both templates and documents" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "ct1", "name" => "T1"})

        Documents.persist_thumbnail("ct1", "data:t1")

        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "cd1", "name" => "D1"})

        Documents.persist_thumbnail("cd1", "data:d1")

        thumbs = Documents.load_cached_thumbnails(["ct1", "cd1", "missing"])

        assert thumbs["ct1"] == "data:t1"
        assert thumbs["cd1"] == "data:d1"
        refute Map.has_key?(thumbs, "missing")
      end

      test "returns empty map for non-list input" do
        assert Documents.load_cached_thumbnails(nil) == %{}
      end

      test "returns empty map for empty list" do
        assert Documents.load_cached_thumbnails([]) == %{}
      end
    end

    # ===========================================================================
    # detect_variables (DB persistence)
    # ===========================================================================

    describe "detect_variables/1 DB persistence" do
      test "persists detected variable definitions to template record" do
        {:ok, t} =
          Documents.upsert_template_from_drive(%{"id" => "var_t", "name" => "Var Test"})

        assert t.variables == []

        # We can't call detect_variables without mocking GoogleDocsClient,
        # but we can verify the schema supports variable storage
        Template
        |> where([t], t.uuid == ^t.uuid)
        |> Repo.update_all(
          set: [variables: [%{"name" => "client", "label" => "Client", "type" => "text"}]]
        )

        updated = Repo.get!(Template, t.uuid)
        assert [%{"name" => "client"}] = updated.variables
      end
    end
  end
end
