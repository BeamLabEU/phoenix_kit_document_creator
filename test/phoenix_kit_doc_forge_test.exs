defmodule PhoenixKitDocForgeTest do
  use ExUnit.Case

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitDocForge.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitDocForge.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns correct key" do
      assert PhoenixKitDocForge.module_key() == "document_creator"
    end

    test "module_name/0 returns correct name" do
      assert PhoenixKitDocForge.module_name() == "Document Creator"
    end

    test "enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitDocForge.enabled?())
    end

    test "enable_system/0 is exported" do
      assert function_exported?(PhoenixKitDocForge, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(PhoenixKitDocForge, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitDocForge.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitDocForge.permission_metadata()
      assert meta.key == PhoenixKitDocForge.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitDocForge.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns base tabs (parent + builder + preview)" do
      tabs = PhoenixKitDocForge.admin_tabs()
      assert is_list(tabs)
      # Base: 3 tabs. Testing tabs are compile-time conditional.
      assert length(tabs) >= 3
    end

    test "parent tab has correct fields" do
      [parent | _] = PhoenixKitDocForge.admin_tabs()
      assert parent.id == :admin_document_creator
      assert parent.label == "Document Creator"
      assert parent.level == :admin
      assert parent.permission == PhoenixKitDocForge.module_key()
      assert parent.group == :admin_modules
    end

    test "parent tab routes to GrapesJS editor" do
      [parent | _] = PhoenixKitDocForge.admin_tabs()
      assert {PhoenixKitDocForge.Web.EditorGrapesjsTestLive, :index} = parent.live_view
    end

    test "subtabs reference parent" do
      [_parent | subtabs] = PhoenixKitDocForge.admin_tabs()

      for subtab <- subtabs do
        assert subtab.parent == :admin_document_creator
      end
    end

    test "includes template builder and preview tabs" do
      tabs = PhoenixKitDocForge.admin_tabs()

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocForge.Web.TemplateBuilderLive, :index}, tab.live_view)
             end)

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocForge.Web.TemplatePreviewLive, :index}, tab.live_view)
             end)
    end

    test "paths use hyphens not underscores" do
      tabs = PhoenixKitDocForge.admin_tabs()

      for tab <- tabs do
        refute String.contains?(tab.path, "_"),
               "Tab #{tab.id} path #{tab.path} contains underscores"
      end
    end
  end

  describe "version/0" do
    test "returns a version string" do
      version = PhoenixKitDocForge.version()
      assert is_binary(version)
      assert version == "0.1.0"
    end
  end

  describe "DocumentFormat" do
    alias PhoenixKitDocForge.DocumentFormat

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

  describe "helper functions" do
    test "chromic_pdf_available?/0 returns boolean" do
      assert is_boolean(PhoenixKitDocForge.chromic_pdf_available?())
    end

    test "chrome_installed?/0 returns boolean" do
      assert is_boolean(PhoenixKitDocForge.chrome_installed?())
    end
  end
end
