defmodule PhoenixKitDocumentCreator.Web.DocumentsLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.Documents

  describe "mount — Google not connected (test env default)" do
    # In the LV test endpoint there are no Google credentials wired up,
    # so `GoogleDocsClient.connection_status/0` returns `{:error, _}`
    # at mount and the LV renders the "Google Account Not Connected"
    # empty state. These tests pin that mount path — they're not full
    # end-to-end tests of the documents/templates list (those need a
    # Drive HTTP stub, see C12 punt list).

    test "documents URL renders the empty-state card", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/document-creator")

      assert html =~ "Google Account Not Connected"
      # Settings link in the empty-state CTA.
      assert html =~ "/en/admin/settings/document-creator"
    end

    test "templates URL renders the empty-state card too", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/document-creator/templates")

      assert html =~ "Google Account Not Connected"
    end
  end

  describe "DB rows present + Google not connected" do
    test "DB rows are NOT shown when Google isn't connected", %{conn: conn} do
      # Register a document directly in the DB.
      attrs = %{
        google_doc_id: "doc-mount-#{System.unique_integer([:positive])}",
        name: "Mount-shown Document #{System.unique_integer([:positive])}"
      }

      {:ok, _} = Documents.register_existing_document(attrs)

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/document-creator")

      # Pin: when Google isn't connected, mount returns empty lists
      # regardless of DB contents. The user sees the "connect first"
      # CTA, not stale DB rows that the user can't actually act on
      # (every action button needs a working Drive client).
      assert html =~ "Google Account Not Connected"
      refute html =~ attrs.name
    end
  end

  describe "handle_info catch-all" do
    # Pinning test for the C5 fix (added Logger.debug) and the prior
    # PR #9 follow-up. Stray messages must not crash the LV.
    test "an unexpected message does not crash the LiveView", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      send(view.pid, :unexpected_message_that_should_be_ignored)
      send(view.pid, {:totally, :unhandled, :tuple})

      # If the catch-all is missing, render/1 raises and the assertion
      # fails because the LV is dead.
      assert render(view) =~ "Document Creator"
      assert Process.alive?(view.pid)
    end
  end

  describe "connected-state actions thread actor_uuid through to context" do
    # Pinning tests for `actor_opts(socket)` threading on every
    # async/destructive `phx-click` handler. Without these, dropping
    # `actor_opts(socket)` from `handle_event("new_template", ...)` (or
    # any sibling) silently regresses to `actor_uuid: nil` on the
    # activity row — the LV smoke test that asserts `render() =~ "..."`
    # would still pass.
    #
    # The Batch 4 retrofit on `GoogleDocsClient.integrations_backend/0`
    # plus the `Test.StubIntegrations` module makes the connected-state
    # mount + Drive-bound clicks reachable without external HTTP.

    alias PhoenixKitDocumentCreator.Test.StubIntegrations

    setup do
      previous = Application.get_env(:phoenix_kit_document_creator, :integrations_backend)

      Application.put_env(
        :phoenix_kit_document_creator,
        :integrations_backend,
        StubIntegrations
      )

      StubIntegrations.reset!()
      StubIntegrations.connected!("admin@example.com")

      # Seed the folder cache so `get_folder_ids/0` doesn't kick off
      # discover_folders/0's parallel API requests.
      PhoenixKit.Settings.update_json_setting_with_module(
        "document_creator_folders",
        %{
          "templates_folder_id" => "stub-templates",
          "documents_folder_id" => "stub-documents",
          "deleted_templates_folder_id" => "stub-deleted-templates",
          "deleted_documents_folder_id" => "stub-deleted-documents"
        },
        "document_creator"
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
          else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)
      end)

      :ok
    end

    test "new_template threads actor_uuid through to template.created activity row",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "lv-tpl-1", "name" => "Untitled Template"}}}
      )

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator/templates")

      render_click(view, "new_template")

      assert_activity_logged("template.created",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "lv-tpl-1"}
      )
    end

    test "new_blank_document threads actor_uuid through to document.created activity row",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "lv-doc-1", "name" => "Untitled Document"}}}
      )

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "new_blank_document")

      assert_activity_logged("document.created",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "lv-doc-1"}
      )
    end

    test "perform_file_action :delete threads actor_uuid through", %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid
      file_id = "lv-doc-del"

      # GET parents → PATCH addParents+removeParents (the move_file flow).
      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
        {:ok, %{status: 200, body: %{"id" => file_id, "parents" => ["src"]}}}
      )

      StubIntegrations.stub_request(
        :patch,
        "/drive/v3/files/#{file_id}",
        {:ok, %{status: 200, body: %{"id" => file_id}}}
      )

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # The toolbar grid only renders rows for files in `@documents`,
      # but the `:perform_file_action` handler is the unified entry
      # point — drive it directly so the test doesn't depend on the
      # connected-mount fixture seeding rows in the right shape.
      send(view.pid, {:perform_file_action, :delete, file_id})
      _ = render(view)

      assert_activity_logged("document.deleted",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => file_id}
      )
    end
  end
end
