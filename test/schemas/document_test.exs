defmodule PhoenixKitDocumentCreator.Schemas.DocumentTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Schemas.Document

  @valid_attrs %{name: "Invoice #1234"}

  defp changeset(attrs) do
    Document.changeset(%Document{}, attrs)
  end

  describe "changeset/2 with valid data" do
    test "is valid with only required fields" do
      cs = changeset(@valid_attrs)
      assert cs.valid?
    end

    test "accepts optional content fields" do
      cs =
        changeset(%{
          name: "Test Doc",
          content_html: "<h1>Hello</h1>",
          content_css: "h1 { color: red; }",
          content_native: %{"components" => []}
        })

      assert cs.valid?
    end

    test "accepts variable_values" do
      cs = changeset(%{name: "Test", variable_values: %{"client" => "Acme"}})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :variable_values) == %{"client" => "Acme"}
    end

    test "accepts baked header/footer fields" do
      cs =
        changeset(%{
          name: "Doc with HF",
          header_html: "<div>Header</div>",
          header_css: "div { font-size: 10px; }",
          header_height: "30mm",
          footer_html: "<div>Footer</div>",
          footer_css: "div { font-size: 8px; }",
          footer_height: "15mm"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :header_html) == "<div>Header</div>"
      assert Ecto.Changeset.get_change(cs, :footer_height) == "15mm"
    end

    test "accepts config map" do
      cs =
        changeset(%{
          name: "Doc",
          config: %{"paper_size" => "letter", "orientation" => "landscape"}
        })

      assert cs.valid?
    end

    test "accepts template_uuid" do
      uuid = Ecto.UUID.generate()
      cs = changeset(%{name: "From template", template_uuid: uuid})
      assert cs.valid?
    end

    test "accepts created_by_uuid" do
      uuid = Ecto.UUID.generate()
      cs = changeset(%{name: "Doc", created_by_uuid: uuid})
      assert cs.valid?
    end

    test "accepts thumbnail" do
      cs = changeset(%{name: "Doc", thumbnail: "data:image/png;base64,abc123"})
      assert cs.valid?
    end
  end

  describe "changeset/2 with invalid data" do
    test "is invalid without name" do
      cs = changeset(%{})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "is invalid with empty string name" do
      cs = changeset(%{name: ""})
      refute cs.valid?
    end

    test "is invalid with name exceeding 255 characters" do
      long_name = String.duplicate("a", 256)
      cs = changeset(%{name: long_name})
      refute cs.valid?
      assert %{name: [msg]} = errors_on(cs)
      assert msg =~ "at most"
    end

    test "name at exactly 255 characters is valid" do
      name = String.duplicate("a", 255)
      cs = changeset(%{name: name})
      assert cs.valid?
    end
  end

  describe "schema defaults" do
    test "default field values on struct" do
      doc = %Document{}
      assert doc.content_html == ""
      assert doc.content_css == ""
      assert doc.variable_values == %{}
      assert doc.header_html == ""
      assert doc.header_height == "25mm"
      assert doc.footer_html == ""
      assert doc.footer_height == "20mm"
      assert doc.config == %{"paper_size" => "a4", "orientation" => "portrait"}
      assert doc.data == %{}
    end
  end

  # Helper to extract error messages from a changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
