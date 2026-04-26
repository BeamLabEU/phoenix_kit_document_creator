defmodule PhoenixKitDocumentCreator.Integration.ActivityLoggingTest do
  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo

  # Per-action pinning tests. These actions are callable from a context
  # function that doesn't depend on a live Google Drive client — the
  # Drive-API-bound actions (template.created / document.created /
  # *.deleted / *.restored / *.exported_pdf / file.reclassified /
  # file.location_accepted / sync.completed) need an HTTP stub layer
  # to test end-to-end and are intentionally out of scope for this
  # sweep (no Req.Test wiring exists yet — see C12 punt list).

  setup do
    # Make sure no prior test rows leak in via the shared sandbox.
    TestRepo.delete_all("phoenix_kit_activities", log: false)

    :ok
  end

  describe "register_existing_document/2" do
    test "logs document.registered_existing with actor_uuid + safe metadata" do
      actor_uuid = Ecto.UUID.generate()

      attrs = %{
        google_doc_id: "doc-#{System.unique_integer([:positive])}",
        name: "Reg Doc #{System.unique_integer([:positive])}",
        path: "documents/order-1",
        folder_id: "folder-A"
      }

      {:ok, doc} = Documents.register_existing_document(attrs, actor_uuid: actor_uuid)

      row =
        assert_activity_logged("document.registered_existing",
          actor_uuid: actor_uuid,
          metadata_has: %{"google_doc_id" => attrs.google_doc_id, "name" => attrs.name}
        )

      assert row.module == "document_creator"
      assert row.resource_type == "document"

      # PII audit: metadata is safe-fields-only — never email, notes,
      # template variable values, etc.
      refute Map.has_key?(row.metadata, "variable_values")
      refute Map.has_key?(row.metadata, "thumbnail")

      _ = doc
    end

    test "no actor_uuid threaded ⇒ row lands with actor_uuid=nil" do
      attrs = %{
        google_doc_id: "doc-#{System.unique_integer([:positive])}",
        name: "No Actor"
      }

      {:ok, _} = Documents.register_existing_document(attrs)

      row = assert_activity_logged("document.registered_existing")
      assert row.actor_uuid == nil
    end
  end

  describe "register_existing_template/2" do
    test "logs template.registered_existing with actor_uuid + safe metadata" do
      actor_uuid = Ecto.UUID.generate()

      attrs = %{
        google_doc_id: "tpl-#{System.unique_integer([:positive])}",
        name: "Reg Tpl #{System.unique_integer([:positive])}"
      }

      {:ok, _tpl} = Documents.register_existing_template(attrs, actor_uuid: actor_uuid)

      row =
        assert_activity_logged("template.registered_existing",
          actor_uuid: actor_uuid,
          metadata_has: %{"google_doc_id" => attrs.google_doc_id, "name" => attrs.name}
        )

      assert row.module == "document_creator"
      assert row.resource_type == "template"
    end
  end

  describe "log_manual_action/2" do
    # Public manual-action helper used by LV "Refresh" button.
    test "logs the given action with actor_uuid + metadata" do
      actor_uuid = Ecto.UUID.generate()

      :ok =
        Documents.log_manual_action("sync.triggered",
          actor_uuid: actor_uuid,
          metadata: %{"source" => "documents_live"}
        )

      row =
        assert_activity_logged("sync.triggered",
          actor_uuid: actor_uuid,
          metadata_has: %{"source" => "documents_live"}
        )

      assert row.mode == "manual"
      assert row.module == "document_creator"
    end

    test "no metadata opt → still logs with actor_uuid" do
      actor_uuid = Ecto.UUID.generate()

      :ok = Documents.log_manual_action("sync.triggered", actor_uuid: actor_uuid)

      row = assert_activity_logged("sync.triggered", actor_uuid: actor_uuid)
      assert row.metadata == %{}
    end
  end

  describe "error-path activity logging (Drive not configured)" do
    # In test env, OAuth is not connected and the folder cache is empty,
    # so every Drive-bound mutation hits its `{:error, :*_not_found}`
    # or `{:error, :not_configured}` branch deterministically without an
    # HTTP stub. These tests pin the user-attempt audit row that lands
    # with `db_pending: true` even when the operation didn't complete —
    # without this, a Drive outage would erase every admin click from
    # the activity feed.

    test "create_template logs db_pending row when templates folder not found" do
      actor_uuid = Ecto.UUID.generate()

      assert {:error, _} = Documents.create_template("Failed Tpl", actor_uuid: actor_uuid)

      row =
        assert_activity_logged("template.created",
          actor_uuid: actor_uuid,
          metadata_has: %{"db_pending" => true, "name" => "Failed Tpl"}
        )

      assert row.resource_type == "template"
      refute Map.has_key?(row.metadata, "google_doc_id")
    end

    test "create_document logs db_pending row when documents folder not found" do
      actor_uuid = Ecto.UUID.generate()

      assert {:error, _} = Documents.create_document("Failed Doc", actor_uuid: actor_uuid)

      row =
        assert_activity_logged("document.created",
          actor_uuid: actor_uuid,
          metadata_has: %{"db_pending" => true, "name" => "Failed Doc"}
        )

      assert row.resource_type == "document"
    end

    test "delete_document logs db_pending row when deleted folder not found" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "doc-#{System.unique_integer([:positive])}"

      assert {:error, _} = Documents.delete_document(file_id, actor_uuid: actor_uuid)

      assert_activity_logged("document.deleted",
        actor_uuid: actor_uuid,
        metadata_has: %{"db_pending" => true, "google_doc_id" => file_id}
      )
    end

    test "delete_template logs db_pending row when deleted folder not found" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "tpl-#{System.unique_integer([:positive])}"

      assert {:error, _} = Documents.delete_template(file_id, actor_uuid: actor_uuid)

      assert_activity_logged("template.deleted",
        actor_uuid: actor_uuid,
        metadata_has: %{"db_pending" => true, "google_doc_id" => file_id}
      )
    end

    test "restore_document logs db_pending row when live folder not found" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "doc-#{System.unique_integer([:positive])}"

      assert {:error, _} = Documents.restore_document(file_id, actor_uuid: actor_uuid)

      assert_activity_logged("document.restored",
        actor_uuid: actor_uuid,
        metadata_has: %{"db_pending" => true, "google_doc_id" => file_id}
      )
    end

    test "restore_template logs db_pending row when live folder not found" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "tpl-#{System.unique_integer([:positive])}"

      assert {:error, _} = Documents.restore_template(file_id, actor_uuid: actor_uuid)

      assert_activity_logged("template.restored",
        actor_uuid: actor_uuid,
        metadata_has: %{"db_pending" => true, "google_doc_id" => file_id}
      )
    end

    test "export_pdf logs db_pending row when Drive not configured" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "doc-#{System.unique_integer([:positive])}"

      assert {:error, _} =
               Documents.export_pdf(file_id, actor_uuid: actor_uuid, name: "Failed.pdf")

      row =
        assert_activity_logged("document.exported_pdf",
          actor_uuid: actor_uuid,
          metadata_has: %{
            "db_pending" => true,
            "google_doc_id" => file_id,
            "name" => "Failed.pdf"
          }
        )

      # PII/size audit: error path never logs a phantom size_bytes.
      refute Map.has_key?(row.metadata, "size_bytes")
    end

    test "set_correct_location logs db_pending row when Drive not configured" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "doc-#{System.unique_integer([:positive])}"

      assert {:error, _} = Documents.set_correct_location(file_id, actor_uuid: actor_uuid)

      assert_activity_logged("file.location_accepted",
        actor_uuid: actor_uuid,
        metadata_has: %{"db_pending" => true, "google_doc_id" => file_id}
      )
    end
  end

  describe "actions not pinned at the integration layer" do
    # Listing here so future sweep planners can find them. These actions
    # all flow through a successful GoogleDocsClient call that needs a
    # Req.Test stub to test deterministically. Error-path coverage is
    # pinned above (deterministic without HTTP stubs because the
    # GoogleDocsClient hits `{:error, :not_configured}` in test env).
    @drive_bound_actions [
      "template.created",
      "document.created",
      "document.created_from_template",
      "template.deleted",
      "document.deleted",
      "template.restored",
      "document.restored",
      "document.exported_pdf",
      "file.reclassified",
      "file.location_accepted",
      "sync.completed"
    ]

    test "drive-bound actions list is documented" do
      # Sanity check that the list is non-empty so the constant doesn't
      # rot to []; the actual coverage punt is documented in the
      # describe-block doc above.
      assert length(@drive_bound_actions) == 11
    end
  end
end
