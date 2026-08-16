defmodule PhoenixKitDocumentCreator.Web.CategoriesLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.{Documents, Taxonomy}

  test "lists existing categories", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, _} = Taxonomy.create_category(%{name: "Financial"})
    {:ok, view, _html} = live(conn, "/en/admin/document-creator/categories")
    assert render(view) =~ "Financial"
  end

  test "selecting a category shows its types", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, cat} = Taxonomy.create_category(%{name: "C"})
    {:ok, _} = Taxonomy.create_type(%{name: "InvoiceType", category_uuid: cat.uuid})
    {:ok, view, _html} = live(conn, "/en/admin/document-creator/categories")

    view
    |> element("button[phx-click='select_category'][phx-value-uuid='#{cat.uuid}']")
    |> render_click()

    assert render(view) =~ "InvoiceType"
  end

  describe "locale-aware category/type names" do
    # `live/2` runs the LiveView in its own process, so `Gettext.put_locale/2`
    # called from the test process never reaches it — DC has no locale-sync
    # on_mount hook of its own (that's the host app's job, see
    # `Andi.Locales.sync_from_phoenix_kit/0`). Rendering with an untranslated
    # category still exercises the real code path (`Taxonomy.localized_name/2`
    # is called either way and falls back to `name`), just not the "different
    # locale, different text" branch — that one is covered directly by the
    # `Taxonomy.localized_name/2` unit tests in `taxonomy_test.exs`.
    test "renders the (untranslated) name via the same localized_name/2 path", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Klient"})

      {:ok, _cat} =
        Taxonomy.update_category(cat, %{
          data: %{
            "_primary_language" => "et",
            "et" => %{"_name" => "Klient"},
            "ru" => %{"_name" => "Клиент"}
          }
        })

      {:ok, _type} = Taxonomy.create_type(%{name: "Hooldusjuhend", category_uuid: cat.uuid})

      {:ok, view, html} = live(conn, "/en/admin/document-creator/categories")
      # Default (primary/"et") tab of a category with no "en" override falls
      # back to the denormalized name, same as before this change.
      assert html =~ "Klient"

      view
      |> element("button[phx-click='select_category'][phx-value-uuid='#{cat.uuid}']")
      |> render_click()

      assert render(view) =~ "Hooldusjuhend"
    end
  end

  describe "presets panel" do
    test "lists presets of the selected category and deletes one", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, cat} = Taxonomy.create_category(%{name: "Legal"})

      {:ok, preset} =
        Documents.save_preset(%{
          name: "Standard",
          scope_id: cat.uuid,
          created_by_uuid: Ecto.UUID.generate()
        })

      {:ok, view, _} = live(conn, "/en/admin/document-creator/categories")
      view |> element("button", "Legal") |> render_click()

      assert render(view) =~ "Standard"

      view
      |> element(~s{button[phx-value-uuid="#{preset.uuid}"][phx-click="delete_preset"]})
      |> render_click()

      assert Documents.list_presets(%{scope_id: cat.uuid}) == []
    end
  end
end
