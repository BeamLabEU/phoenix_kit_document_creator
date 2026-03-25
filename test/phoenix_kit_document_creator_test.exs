defmodule PhoenixKitDocumentCreatorTest do
  use ExUnit.Case

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitDocumentCreator.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitDocumentCreator.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns correct key" do
      assert PhoenixKitDocumentCreator.module_key() == "document_creator"
    end

    test "module_name/0 returns correct name" do
      assert PhoenixKitDocumentCreator.module_name() == "Document Creator"
    end

    test "enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitDocumentCreator.enabled?())
    end

    test "enable_system/0 is exported" do
      assert function_exported?(PhoenixKitDocumentCreator, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(PhoenixKitDocumentCreator, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitDocumentCreator.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitDocumentCreator.permission_metadata()
      assert meta.key == PhoenixKitDocumentCreator.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitDocumentCreator.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns base tabs (8 minimum)" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()
      assert is_list(tabs)

      # Base: 10 tabs (landing, template new/edit, document edit, headers list/new/edit, footers list/new/edit).
      # Testing tabs are compile-time conditional.
      assert length(tabs) >= 8
    end

    test "parent tab has correct fields" do
      [parent | _] = PhoenixKitDocumentCreator.admin_tabs()
      assert parent.id == :admin_document_creator
      assert parent.label == "Document Creator"
      assert parent.level == :admin
      assert parent.permission == PhoenixKitDocumentCreator.module_key()
      assert parent.group == :admin_modules
    end

    test "parent tab routes to DocumentsLive" do
      [parent | _] = PhoenixKitDocumentCreator.admin_tabs()
      assert {PhoenixKitDocumentCreator.Web.DocumentsLive, :index} = parent.live_view
    end

    test "subtabs reference parent" do
      [_parent | subtabs] = PhoenixKitDocumentCreator.admin_tabs()

      for subtab <- subtabs do
        assert subtab.parent == :admin_document_creator
      end
    end

    test "includes template editor, document editor, and header/footer tabs" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocumentCreator.Web.TemplateEditorLive, _action}, tab.live_view)
             end)

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocumentCreator.Web.DocumentEditorLive, :edit}, tab.live_view)
             end)

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocumentCreator.Web.HeaderFooterLive, :headers}, tab.live_view)
             end)

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocumentCreator.Web.HeaderFooterLive, :footers}, tab.live_view)
             end)
    end

    test "paths use hyphens not underscores (except route params)" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()

      for tab <- tabs do
        # Strip route params like :uuid before checking for underscores
        path_without_params = Regex.replace(~r/:[a-z_]+/, tab.path, "")

        refute String.contains?(path_without_params, "_"),
               "Tab #{tab.id} path #{tab.path} contains underscores"
      end
    end
  end

  describe "version/0" do
    test "returns a version string" do
      version = PhoenixKitDocumentCreator.version()
      assert is_binary(version)
      assert version == "0.1.1"
    end
  end

  describe "DocumentFormat" do
    alias PhoenixKitDocumentCreator.DocumentFormat

    test "new/1 creates a format struct" do
      doc = DocumentFormat.new("<h1>Test</h1>")
      assert doc.schema_version == 1
      assert doc.content_html == "<h1>Test</h1>"
      assert is_binary(doc.content_text)
    end

    test "extract_variables/1 finds template variables" do
      vars =
        DocumentFormat.extract_variables("<p>Hello {{ name }}, your total is {{ amount }}</p>")

      assert "amount" in vars
      assert "name" in vars
    end

    test "strip_html/1 removes tags" do
      text = DocumentFormat.strip_html("<h1>Title</h1><p>Body text</p>")
      assert String.contains?(text, "Title")
      assert String.contains?(text, "Body text")
      refute String.contains?(text, "<")
    end

    test "to_json/1 and from_json/1 round-trip" do
      doc = DocumentFormat.new("<p>test</p>", metadata: %{"editor" => "test"})
      json = DocumentFormat.to_json(doc)
      restored = DocumentFormat.from_json(json)
      assert restored.content_html == doc.content_html
      assert restored.metadata == doc.metadata
    end

    test "sample_html/0 returns non-empty HTML" do
      html = DocumentFormat.sample_html()
      assert is_binary(html)
      assert String.contains?(html, "Service Agreement")
    end
  end

  describe "Variable" do
    alias PhoenixKitDocumentCreator.Variable

    test "extract_from_html/1 finds template variables" do
      vars = Variable.extract_from_html("<p>Hello {{ name }}, total: {{ amount }}</p>")
      assert "amount" in vars
      assert "name" in vars
    end

    test "extract_from_html/1 returns empty list for nil" do
      assert Variable.extract_from_html(nil) == []
    end

    test "build_definitions/1 creates Variable structs" do
      defs = Variable.build_definitions(["company", "contract_date"])
      assert length(defs) == 2
      assert %Variable{name: "company", label: "Company", type: :text} = hd(defs)
    end

    test "guess_type/1 detects date, currency, multiline" do
      assert Variable.guess_type("contract_date") == :date
      assert Variable.guess_type("total_amount") == :currency
      assert Variable.guess_type("description") == :multiline
      assert Variable.guess_type("company") == :text
    end

    test "humanize/1 converts underscore names" do
      assert Variable.humanize("client_name") == "Client Name"
      assert Variable.humanize("amount") == "Amount"
    end
  end

  describe "helper functions" do
    test "chromic_pdf_available?/0 returns boolean" do
      assert is_boolean(PhoenixKitDocumentCreator.chromic_pdf_available?())
    end

    test "chrome_installed?/0 returns boolean" do
      assert is_boolean(PhoenixKitDocumentCreator.chrome_installed?())
    end
  end
end
