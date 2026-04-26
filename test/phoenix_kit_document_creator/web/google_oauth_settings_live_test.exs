defmodule PhoenixKitDocumentCreator.Web.GoogleOAuthSettingsLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  import ExUnit.CaptureLog

  describe "mount" do
    test "renders the settings page header", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/settings/document-creator")

      assert html =~ "Document Creator Settings"
    end
  end

  describe "handle_info catch-all" do
    setup do
      # The catch-all clause logs at :debug, but config/test.exs pins
      # Logger level to :warning — capture_log can't see filtered events.
      # Bump to :debug for this describe so the assertion exercises the
      # real call site instead of just process-alive tautologies.
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    test "an unexpected message does not crash the LiveView and logs at :debug",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :totally_unexpected)
          send(view.pid, {:not_a_known_tuple, "data"})
          _ = render(view)
        end)

      assert log =~ "GoogleOAuthSettingsLive"
      assert log =~ "ignoring unexpected message"
      assert Process.alive?(view.pid)
    end
  end
end
