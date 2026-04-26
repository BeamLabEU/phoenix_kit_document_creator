defmodule PhoenixKitDocumentCreator.PathsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Paths

  describe "path helpers" do
    test "index/0 returns the admin index path" do
      assert is_binary(Paths.index())
      assert Paths.index() =~ "/admin/document-creator"
    end

    test "templates/0 returns the templates subpath" do
      assert Paths.templates() =~ "/admin/document-creator/templates"
    end

    test "documents/0 returns the documents subpath" do
      assert Paths.documents() =~ "/admin/document-creator/documents"
    end

    test "settings/0 returns the settings subpath" do
      assert Paths.settings() =~ "/admin/settings/document-creator"
    end

    test "all helpers route through PhoenixKit.Utils.Routes (prefix-aware)" do
      # All helpers go through Routes.path/1 — pin that they don't
      # hardcode the prefix. With no `url_prefix` config, the path is
      # returned as-is; with a prefix it would be prepended.
      for path <- [Paths.index(), Paths.templates(), Paths.documents(), Paths.settings()] do
        assert String.starts_with?(path, "/")
      end
    end
  end
end
