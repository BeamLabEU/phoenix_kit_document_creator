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

  describe "variables step rendering edge cases" do
    test "renders Unicode variable names without crashing" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "Café Report"},
          variables: [
            %{name: "客户_名称", label: "Client Name", type: :text},
            %{name: "総合金額", label: "Total Amount", type: :currency}
          ],
          creating: false
        )

      assert html =~ "客户_名称"
      assert html =~ "総合金額"
    end

    test "renders multiline variable as textarea, others as input" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [
            %{name: "description", label: "Description", type: :multiline},
            %{name: "company", label: "Company", type: :text}
          ],
          creating: false
        )

      assert html =~ ~r/<textarea[^>]*name="var\[description\]"/
      assert html =~ ~r/<input[^>]*name="var\[company\]"/
    end

    test "renders very long template name without truncation in form value" do
      long_name = String.duplicate("a", 250)

      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => long_name},
          variables: [],
          creating: false
        )

      # The pre-filled doc_name field surfaces the full template name —
      # truncation belongs in the LV after submit, not in the modal.
      assert html =~ long_name
    end

    test "creating=true disables the submit button (server-side guard)" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [],
          creating: true
        )

      # `disabled={@creating}` and `phx-disable-with` together: the
      # client transition uses phx-disable-with text and the server-set
      # `disabled` attribute survives a re-render.
      assert html =~ ~r/type="submit"[^>]*disabled/
    end

    test "Cancel button does not have phx-disable-with (UI-state-only)" do
      html =
        render_component(&CreateDocumentModal.modal/1,
          open: true,
          templates: [],
          step: "variables",
          selected_template: %{"id" => "tpl-1", "name" => "T"},
          variables: [],
          creating: false
        )

      # Only async/destructive buttons need phx-disable-with. Cancel is
      # a pure UI-state toggle and doesn't.
      refute html =~ ~r/phx-click="modal_close"[^>]*phx-disable-with/
    end
  end
end
