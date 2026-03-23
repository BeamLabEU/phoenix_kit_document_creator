defmodule PhoenixKitDocumentCreator.Integration.DocumentsTest do
  use PhoenixKitDocumentCreator.DataCase, async: true

  alias PhoenixKitDocumentCreator.Documents

  # ── Headers & Footers ──────────────────────────────────────────

  describe "create_header/1" do
    test "creates a header record" do
      assert {:ok, header} = Documents.create_header(%{name: "Test Header"})
      assert header.name == "Test Header"
      assert header.type == "header"
      assert header.height == "25mm"
    end
  end

  describe "create_footer/1" do
    test "creates a footer record" do
      assert {:ok, footer} = Documents.create_footer(%{name: "Test Footer"})
      assert footer.name == "Test Footer"
      assert footer.type == "footer"
    end
  end

  describe "list_headers/0 and list_footers/0" do
    test "lists only headers" do
      {:ok, _header} = Documents.create_header(%{name: "H1"})
      {:ok, _footer} = Documents.create_footer(%{name: "F1"})

      headers = Documents.list_headers()
      assert length(headers) == 1
      assert hd(headers).type == "header"
    end

    test "lists only footers" do
      {:ok, _header} = Documents.create_header(%{name: "H1"})
      {:ok, _footer} = Documents.create_footer(%{name: "F1"})

      footers = Documents.list_footers()
      assert length(footers) == 1
      assert hd(footers).type == "footer"
    end
  end

  describe "update_header_footer/2" do
    test "updates a header" do
      {:ok, header} = Documents.create_header(%{name: "Old", html: "<p>old</p>"})
      {:ok, updated} = Documents.update_header_footer(header, %{name: "New", html: "<p>new</p>"})
      assert updated.name == "New"
      assert updated.html == "<p>new</p>"
    end
  end

  describe "delete_header_footer/1" do
    test "deletes a header" do
      {:ok, header} = Documents.create_header(%{name: "To Delete"})
      assert {:ok, _} = Documents.delete_header_footer(header)
      assert Documents.get_header_footer(header.uuid) == nil
    end
  end

  # ── Templates ──────────────────────────────────────────────────

  describe "create_template/1" do
    test "creates a template with name" do
      assert {:ok, template} = Documents.create_template(%{name: "Invoice"})
      assert template.name == "Invoice"
      assert template.status == "published"
    end

    test "generates a slug from name" do
      {:ok, template} = Documents.create_template(%{name: "My Great Template"})
      assert template.slug == "my-great-template"
    end

    test "fails without name" do
      assert {:error, changeset} = Documents.create_template(%{})
      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "list_templates/0" do
    test "excludes trashed templates by default" do
      {:ok, _active} = Documents.create_template(%{name: "Active"})
      {:ok, trashed} = Documents.create_template(%{name: "Trashed"})
      Documents.update_template(trashed, %{status: "trashed"})

      templates = Documents.list_templates()
      assert length(templates) == 1
      assert hd(templates).name == "Active"
    end
  end

  describe "update_template/2" do
    test "updates template fields" do
      {:ok, template} = Documents.create_template(%{name: "V1"})
      {:ok, updated} = Documents.update_template(template, %{name: "V2", description: "Updated"})
      assert updated.name == "V2"
      assert updated.description == "Updated"
    end
  end

  describe "delete_template/1" do
    test "deletes a template" do
      {:ok, template} = Documents.create_template(%{name: "To Delete"})
      assert {:ok, _} = Documents.delete_template(template)
      assert Documents.get_template(template.uuid) == nil
    end
  end

  # ── Documents ──────────────────────────────────────────────────

  describe "create_document/1" do
    test "creates a document with name" do
      assert {:ok, doc} = Documents.create_document(%{name: "My Doc"})
      assert doc.name == "My Doc"
    end

    test "creates a document with baked header/footer content" do
      assert {:ok, doc} =
               Documents.create_document(%{
                 name: "Doc with HF",
                 header_html: "<h1>Header</h1>",
                 header_css: ".h { color: red; }",
                 header_height: "30mm",
                 footer_html: "<p>Footer</p>",
                 footer_css: ".f { color: blue; }",
                 footer_height: "20mm"
               })

      assert doc.header_html == "<h1>Header</h1>"
      assert doc.header_css == ".h { color: red; }"
      assert doc.header_height == "30mm"
      assert doc.footer_html == "<p>Footer</p>"
      assert doc.footer_height == "20mm"
    end
  end

  describe "create_document_from_template/3" do
    test "creates a document from a template with variables rendered" do
      {:ok, template} =
        Documents.create_template(%{
          name: "Contract",
          content_html: "<p>Hello {{ client_name }}</p>",
          content_css: ".contract { margin: 0; }"
        })

      assert {:ok, doc} =
               Documents.create_document_from_template(
                 template.uuid,
                 %{"client_name" => "Acme Corp"},
                 name: "Acme Contract"
               )

      assert doc.name == "Acme Contract"
      assert doc.template_uuid == template.uuid
      assert doc.content_html == "<p>Hello Acme Corp</p>"
      assert doc.content_css == ".contract { margin: 0; }"
      assert doc.variable_values == %{"client_name" => "Acme Corp"}
    end

    test "bakes header/footer content from template's linked records" do
      {:ok, header} =
        Documents.create_header(%{
          name: "Invoice Header",
          html: "<h1>INVOICE</h1>",
          css: ".inv { font-weight: bold; }",
          height: "30mm"
        })

      {:ok, footer} =
        Documents.create_footer(%{
          name: "Page Footer",
          html: "<p>Page 1</p>",
          css: ".pg { font-size: 9px; }",
          height: "15mm"
        })

      {:ok, template} =
        Documents.create_template(%{
          name: "Invoice Template",
          content_html: "<p>Amount: {{ amount }}</p>",
          header_uuid: header.uuid,
          footer_uuid: footer.uuid
        })

      {:ok, doc} =
        Documents.create_document_from_template(
          template.uuid,
          %{"amount" => "$500"}
        )

      # Header/footer content is baked (copied) into the document
      assert doc.header_html == "<h1>INVOICE</h1>"
      assert doc.header_css == ".inv { font-weight: bold; }"
      assert doc.header_height == "30mm"
      assert doc.footer_html == "<p>Page 1</p>"
      assert doc.footer_css == ".pg { font-size: 9px; }"
      assert doc.footer_height == "15mm"
      assert doc.content_html == "<p>Amount: $500</p>"
    end

    test "document survives header/footer deletion" do
      {:ok, header} = Documents.create_header(%{name: "Temp Header", html: "<b>H</b>"})

      {:ok, template} =
        Documents.create_template(%{
          name: "Tmpl",
          content_html: "<p>Body</p>",
          header_uuid: header.uuid
        })

      {:ok, doc} =
        Documents.create_document_from_template(template.uuid, %{})

      # Delete the header — document should be unaffected
      Documents.delete_header_footer(header)

      reloaded = Documents.get_document(doc.uuid)
      assert reloaded.header_html == "<b>H</b>"
      assert reloaded.name == "Tmpl"
    end

    test "document survives template deletion" do
      {:ok, template} =
        Documents.create_template(%{name: "Ephemeral", content_html: "<p>Content</p>"})

      {:ok, doc} =
        Documents.create_document_from_template(template.uuid, %{})

      # Delete the template
      Documents.delete_template(template)

      reloaded = Documents.get_document(doc.uuid)
      assert reloaded.content_html == "<p>Content</p>"
      # template_uuid is nilified by on_delete: :nilify_all
      assert reloaded.template_uuid == nil
    end

    test "returns error for nonexistent template" do
      assert {:error, :template_not_found} =
               Documents.create_document_from_template(
                 "00000000-0000-0000-0000-000000000000",
                 %{}
               )
    end
  end

  describe "list_documents/0" do
    test "returns all documents" do
      {:ok, _d1} = Documents.create_document(%{name: "First"})
      {:ok, _d2} = Documents.create_document(%{name: "Second"})

      docs = Documents.list_documents()
      assert length(docs) == 2
      names = Enum.map(docs, & &1.name)
      assert "First" in names
      assert "Second" in names
    end
  end

  describe "delete_document/1" do
    test "deletes a document" do
      {:ok, doc} = Documents.create_document(%{name: "To Delete"})
      assert {:ok, _} = Documents.delete_document(doc)
      assert Documents.get_document(doc.uuid) == nil
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
