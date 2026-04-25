defmodule PhoenixKitDocumentCreator.Web.Components.CreateDocumentModalTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitDocumentCreator.Web.Components.CreateDocumentModal

  # Render the modal as a function component so we can pin the
  # phx-disable-with attribute on the async-triggering buttons without
  # standing up a full LV mount with a Drive stub.

  describe "choose step" do
    test "Blank Document button has phx-disable-with" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "choose"
        )

      # The button text and the attribute must both appear on the same
      # button. Using a regex to keep the assertion specific.
      assert html =~ "phx-click=\"modal_create_blank\""
      assert html =~ ~r/phx-click="modal_create_blank"[^>]*phx-disable-with="Creating[^"]+"/
    end
  end

  describe "variables step" do
    test "Create Document submit button has phx-disable-with" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [],
          creating: false
        )

      assert html =~ "phx-submit=\"modal_create_from_template\""
      # The submit button has both `disabled={@creating}` and
      # `phx-disable-with` so a fast double-click is suppressed both
      # by server state and by the client transition.
      assert html =~ ~r/type="submit"[^>]*phx-disable-with="Creating[^"]+"/
    end
  end

  describe "open=false" do
    test "renders nothing visible when closed" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: false,
          templates: [],
          step: "choose"
        )

      refute html =~ "modal-open"
    end
  end
end
