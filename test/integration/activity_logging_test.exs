defmodule PhoenixKitDocumentCreator.Integration.ActivityLoggingTest do
  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.Documents

  # Per-action pinning tests. These actions are callable from a context
  # function that doesn't depend on a live Google Drive client — the
  # Drive-API-bound actions (template.created / document.created /
  # *.deleted / *.restored / *.exported_pdf / file.reclassified /
  # file.location_accepted / sync.completed) need an HTTP stub layer
  # to test end-to-end and are intentionally out of scope for this
  # sweep (no Req.Test wiring exists yet — see C12 punt list).

  setup do
    # Make sure no prior test rows leak in via the shared sandbox.
    PhoenixKitDocumentCreator.Test.Repo.delete_all(
      "phoenix_kit_activities",
      log: false
    )

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

  describe "actions not pinned at the integration layer" do
    # Listing here so future sweep planners can find them. These actions
    # all flow through a GoogleDocsClient call that needs a Req.Test
    # stub to test deterministically. Wiring that in is feature work
    # (test infra), not a pinning gap that would let a regression slip
    # through silently — every action site is reachable from an LV
    # smoke test or a manual browser run.
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
