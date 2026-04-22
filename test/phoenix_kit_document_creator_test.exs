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
    test "returns 3 tabs (parent + documents + templates)" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()
      assert is_list(tabs)
      assert length(tabs) == 3
    end

    test "parent tab has correct fields" do
      [parent | _] = PhoenixKitDocumentCreator.admin_tabs()
      assert parent.id == :admin_document_creator
      assert parent.label == "Document Creator"
      assert parent.level == :admin
      assert parent.permission == PhoenixKitDocumentCreator.module_key()
      assert parent.group == :admin_modules
    end

    test "parent tab routes to DocumentsLive :documents" do
      [parent | _] = PhoenixKitDocumentCreator.admin_tabs()
      assert {PhoenixKitDocumentCreator.Web.DocumentsLive, :documents} = parent.live_view
    end

    test "subtabs reference parent" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()
      [_parent | subtabs] = tabs

      for subtab <- subtabs do
        assert subtab.parent == :admin_document_creator,
               "Tab #{subtab.id} references unknown parent #{subtab.parent}"
      end
    end

    test "includes documents and templates subtabs" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocumentCreator.Web.DocumentsLive, :documents}, tab.live_view) and
                 tab.id == :admin_document_creator_documents
             end)

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocumentCreator.Web.DocumentsLive, :templates}, tab.live_view) and
                 tab.id == :admin_document_creator_templates
             end)
    end

    test "paths use hyphens not underscores (except route params)" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()

      for tab <- tabs do
        path_without_params = Regex.replace(~r/:[a-z_]+/, tab.path, "")

        refute String.contains?(path_without_params, "_"),
               "Tab #{tab.id} path #{tab.path} contains underscores"
      end
    end
  end

  describe "required_integrations/0" do
    test "declares google as required" do
      assert PhoenixKitDocumentCreator.required_integrations() == ["google"]
    end
  end

  describe "version/0" do
    test "returns a version string" do
      version = PhoenixKitDocumentCreator.version()
      assert is_binary(version)
      assert version == "0.2.7"
    end
  end

  describe "Variable" do
    alias PhoenixKitDocumentCreator.Variable

    test "extract_variables/1 finds template variables" do
      vars = Variable.extract_variables("Hello {{ name }}, total: {{ amount }}")
      assert "amount" in vars
      assert "name" in vars
    end

    test "extract_variables/1 returns empty list for nil" do
      assert Variable.extract_variables(nil) == []
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
end
