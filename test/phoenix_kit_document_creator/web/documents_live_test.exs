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
end
