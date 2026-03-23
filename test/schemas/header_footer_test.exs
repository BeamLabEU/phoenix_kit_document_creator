defmodule PhoenixKitDocumentCreator.Schemas.HeaderFooterTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Schemas.HeaderFooter

  @valid_header_attrs %{name: "Company Header", type: "header"}
  @valid_footer_attrs %{name: "Page Footer", type: "footer"}

  defp changeset(attrs) do
    HeaderFooter.changeset(%HeaderFooter{}, attrs)
  end

  describe "changeset/2 with valid data" do
    test "is valid with required fields for header" do
      cs = changeset(@valid_header_attrs)
      assert cs.valid?
    end

    test "is valid with required fields for footer" do
      cs = changeset(@valid_footer_attrs)
      assert cs.valid?
    end

    test "accepts optional html, css, and native fields" do
      cs =
        changeset(%{
          name: "Rich Header",
          type: "header",
          html: "<div>Logo here</div>",
          css: "div { display: flex; }",
          native: %{"components" => []}
        })

      assert cs.valid?
    end

    test "accepts custom height" do
      cs = changeset(%{name: "Tall Header", type: "header", height: "40mm"})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :height) == "40mm"
    end

    test "accepts data map" do
      cs = changeset(%{name: "Header", type: "header", data: %{"key" => "value"}})
      assert cs.valid?
    end

    test "accepts created_by_uuid" do
      uuid = Ecto.UUID.generate()
      cs = changeset(%{name: "Header", type: "header", created_by_uuid: uuid})
      assert cs.valid?
    end
  end

  describe "changeset/2 with invalid data" do
    test "is invalid without name" do
      cs = changeset(%{type: "header"})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "is invalid without type" do
      cs = changeset(%{name: "No Type"})
      refute cs.valid?
      assert %{type: _} = errors_on(cs)
    end

    test "is invalid with empty name" do
      cs = changeset(%{name: "", type: "header"})
      refute cs.valid?
    end

    test "is invalid with name exceeding 255 characters" do
      cs = changeset(%{name: String.duplicate("a", 256), type: "header"})
      refute cs.valid?
    end

    test "name at exactly 255 characters is valid" do
      cs = changeset(%{name: String.duplicate("a", 255), type: "header"})
      assert cs.valid?
    end
  end

  describe "type validation" do
    test "accepts 'header'" do
      cs = changeset(%{name: "H", type: "header"})
      assert cs.valid?
    end

    test "accepts 'footer'" do
      cs = changeset(%{name: "F", type: "footer"})
      assert cs.valid?
    end

    test "rejects invalid type" do
      cs = changeset(%{name: "X", type: "sidebar"})
      refute cs.valid?
      assert %{type: [_]} = errors_on(cs)
    end

    test "rejects empty string type" do
      cs = changeset(%{name: "X", type: ""})
      refute cs.valid?
    end

    test "rejects nil type" do
      cs = changeset(%{name: "X", type: nil})
      refute cs.valid?
    end
  end

  describe "height validation" do
    test "height has max length of 20 characters" do
      cs = changeset(%{name: "H", type: "header", height: String.duplicate("a", 21)})
      refute cs.valid?
      assert %{height: [_]} = errors_on(cs)
    end

    test "height at exactly 20 characters is valid" do
      cs = changeset(%{name: "H", type: "header", height: String.duplicate("a", 20)})
      assert cs.valid?
    end
  end

  describe "schema defaults" do
    test "default field values on struct" do
      hf = %HeaderFooter{}
      assert hf.html == ""
      assert hf.css == ""
      assert hf.height == "25mm"
      assert hf.data == %{}
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
