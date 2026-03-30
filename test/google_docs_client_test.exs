defmodule PhoenixKitDocumentCreator.GoogleDocsClientTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  describe "module interface" do
    test "module compiles and is loaded" do
      assert Code.ensure_loaded?(GoogleDocsClient)
    end

    test "exports credential functions" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:get_credentials, 0} in exports
      assert {:save_credentials, 1} in exports
    end

    test "exports auth functions" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:authorization_url, 1} in exports
      assert {:exchange_code, 2} in exports
      assert {:refresh_access_token, 0} in exports
      assert {:connection_status, 0} in exports
    end

    test "exports folder functions" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:find_folder_by_name, 1} in exports
      assert {:find_folder_by_name, 2} in exports
      assert {:create_folder, 1} in exports
      assert {:create_folder, 2} in exports
      assert {:find_or_create_folder, 1} in exports
      assert {:find_or_create_folder, 2} in exports
      assert {:ensure_folder_path, 1} in exports
      assert {:ensure_folder_path, 2} in exports
      assert {:discover_folders, 0} in exports
      assert {:get_folder_ids, 0} in exports
      assert {:get_folder_url, 1} in exports
      assert {:get_folder_config, 0} in exports
      assert {:list_subfolders, 0} in exports
      assert {:list_subfolders, 1} in exports
    end

    test "exports document functions" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:create_document, 1} in exports
      assert {:create_document, 2} in exports
      assert {:get_document, 1} in exports
      assert {:batch_update, 2} in exports
      assert {:replace_all_text, 2} in exports
      assert {:get_document_text, 1} in exports
    end

    test "exports Drive functions" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:move_file, 2} in exports
      assert {:copy_file, 2} in exports
      assert {:copy_file, 3} in exports
      assert {:export_pdf, 1} in exports
      assert {:fetch_thumbnail, 1} in exports
      assert {:list_folder_files, 1} in exports
      assert {:validate_file_id, 1} in exports
    end
  end

  describe "get_edit_url/1" do
    test "returns a Google Docs URL for valid doc ID" do
      url = GoogleDocsClient.get_edit_url("abc123")
      assert url == "https://docs.google.com/document/d/abc123/edit"
    end

    test "returns nil for nil" do
      assert GoogleDocsClient.get_edit_url(nil) == nil
    end

    test "returns nil for empty string" do
      assert GoogleDocsClient.get_edit_url("") == nil
    end
  end

  describe "get_folder_url/1" do
    test "returns a Drive folder URL for valid folder ID" do
      url = GoogleDocsClient.get_folder_url("folder123")
      assert url == "https://drive.google.com/drive/folders/folder123"
    end

    test "returns nil for nil" do
      assert GoogleDocsClient.get_folder_url(nil) == nil
    end

    test "returns nil for empty string" do
      assert GoogleDocsClient.get_folder_url("") == nil
    end
  end

  describe "list_folder_files/1" do
    test "returns {:ok, []} for nil folder ID" do
      assert GoogleDocsClient.list_folder_files(nil) == {:ok, []}
    end

    test "returns {:ok, []} for empty folder ID" do
      assert GoogleDocsClient.list_folder_files("") == {:ok, []}
    end
  end

  describe "fetch_thumbnail/1" do
    test "returns {:error, :no_doc_id} for nil" do
      assert GoogleDocsClient.fetch_thumbnail(nil) == {:error, :no_doc_id}
    end

    test "returns {:error, :no_doc_id} for empty string" do
      assert GoogleDocsClient.fetch_thumbnail("") == {:error, :no_doc_id}
    end
  end

  describe "replace_all_text/2" do
    test "returns {:ok, %{}} for empty variables map" do
      assert GoogleDocsClient.replace_all_text("any_doc_id", %{}) == {:ok, %{}}
    end
  end

  describe "validate_file_id/1" do
    test "accepts valid alphanumeric IDs" do
      assert {:ok, "abc123"} = GoogleDocsClient.validate_file_id("abc123")
    end

    test "accepts IDs with hyphens and underscores" do
      assert {:ok, "abc-123_XYZ"} = GoogleDocsClient.validate_file_id("abc-123_XYZ")
    end

    test "rejects IDs with slashes" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.validate_file_id("abc/123")
    end

    test "rejects IDs with query strings" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.validate_file_id("abc?q=1")
    end

    test "rejects empty string" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.validate_file_id("")
    end

    test "rejects nil" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.validate_file_id(nil)
    end
  end

  describe "move_file/2" do
    test "rejects invalid file ID" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.move_file("../etc/passwd", "folder123")
    end

    test "rejects invalid folder ID" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.move_file("file123", "folder/bad")
    end
  end
end
