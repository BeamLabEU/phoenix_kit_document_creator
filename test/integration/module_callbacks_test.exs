defmodule PhoenixKitDocumentCreator.Integration.ModuleCallbacksTest do
  @moduledoc """
  Integration coverage for the optional `PhoenixKit.Module` callbacks
  that touch Settings (`enabled?/0`, `enable_system/0`, `disable_system/0`)
  and the metadata callbacks (`css_sources/0`, `children/0`,
  `settings_tabs/0`). The unit-suite tests in
  `test/phoenix_kit_document_creator_test.exs` only check function
  exports — these tests exercise the bodies through real Settings
  reads/writes, lifting top-level coverage past the rescue/catch
  shortcut.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  describe "enabled?/0 + enable_system/0 + disable_system/0" do
    test "returns false when setting is missing or false" do
      # Default. Settings.get_boolean_setting/2 returns the second arg
      # when no row exists.
      refute PhoenixKitDocumentCreator.enabled?()
    end

    test "enable_system/0 flips the setting to true" do
      assert {:ok, _setting} = PhoenixKitDocumentCreator.enable_system()
      assert PhoenixKitDocumentCreator.enabled?()
    end

    test "disable_system/0 flips the setting to false" do
      _ = PhoenixKitDocumentCreator.enable_system()
      assert PhoenixKitDocumentCreator.enabled?()

      assert {:ok, _setting} = PhoenixKitDocumentCreator.disable_system()
      refute PhoenixKitDocumentCreator.enabled?()
    end
  end

  describe "metadata callbacks" do
    test "css_sources/0 returns the OTP app name list" do
      assert PhoenixKitDocumentCreator.css_sources() == [:phoenix_kit_document_creator]
    end

    test "children/0 returns an empty list (no module-specific children)" do
      assert PhoenixKitDocumentCreator.children() == []
    end

    test "settings_tabs/0 returns at least one Tab struct with the doc-creator path" do
      tabs = PhoenixKitDocumentCreator.settings_tabs()
      assert is_list(tabs)
      assert Enum.any?(tabs, fn tab -> tab.path == "document-creator" end)
    end

    test "permission_metadata/0 key matches module_key/0" do
      assert PhoenixKitDocumentCreator.permission_metadata().key ==
               PhoenixKitDocumentCreator.module_key()
    end

    test "version/0 matches mix.exs declared version" do
      mix_version = Mix.Project.config()[:version]
      assert PhoenixKitDocumentCreator.version() == mix_version
    end
  end
end
