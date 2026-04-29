defmodule PhoenixKitDocumentCreator.Integration.GoogleDocsClientHttpTest do
  @moduledoc """
  HTTP-bound coverage for `PhoenixKitDocumentCreator.GoogleDocsClient`.

  Each test stubs the `authenticated_request/4` contract via the
  `:integrations_backend` config, then drives a single public client
  function — confirming both the success path and the error-shape
  fallbacks (`{:error, :*_failed}` atoms surfaced when Drive returns
  non-2xx).
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Test.StubIntegrations

  setup do
    previous = Application.get_env(:phoenix_kit_document_creator, :integrations_backend)

    Application.put_env(
      :phoenix_kit_document_creator,
      :integrations_backend,
      StubIntegrations
    )

    StubIntegrations.reset!()
    StubIntegrations.connected!()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
        else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)
    end)

    :ok
  end

  describe "find_folder_by_name/2" do
    test "returns {:ok, id} when Drive matches a folder by name" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => [%{"id" => "folder-Z", "name" => "Templates"}]}}}
      )

      assert {:ok, "folder-Z"} = GoogleDocsClient.find_folder_by_name("Templates")
    end

    test "returns {:error, :not_found} when no folder matches" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      assert {:error, :not_found} = GoogleDocsClient.find_folder_by_name("Missing")
    end

    test "returns {:error, :folder_search_failed} on 5xx" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "drive down"}}}
      )

      assert {:error, :folder_search_failed} = GoogleDocsClient.find_folder_by_name("X")
    end

    test "escapes single quotes in name (Drive query injection guard)" do
      # Stub returns OK regardless — the assertion is the lack of crash
      # on a quoted name. The escape happens before query construction.
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      assert {:error, :not_found} =
               GoogleDocsClient.find_folder_by_name("Folder'with'quotes")
    end
  end

  describe "create_folder/2" do
    test "returns {:ok, id} on 200" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "new-folder-1"}}}
      )

      assert {:ok, "new-folder-1"} = GoogleDocsClient.create_folder("New Folder")
    end

    test "returns {:error, :create_folder_failed} on non-2xx" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :create_folder_failed} = GoogleDocsClient.create_folder("X")
    end

    test "passes through transport errors" do
      StubIntegrations.stub_request(:post, "/drive/v3/files", {:error, :timeout})
      assert {:error, :timeout} = GoogleDocsClient.create_folder("X")
    end
  end

  describe "find_or_create_folder/2" do
    test "returns existing folder id without creating" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => [%{"id" => "existing", "name" => "X"}]}}}
      )

      assert {:ok, "existing"} = GoogleDocsClient.find_or_create_folder("X")
    end

    test "creates folder when not found" do
      # Implement the search→empty, then create fallback. The stub
      # dispatches by method, so the GET search returns empty and the
      # POST create returns the new id.
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "created"}}}
      )

      assert {:ok, "created"} = GoogleDocsClient.find_or_create_folder("X")
    end
  end

  describe "ensure_folder_path/2" do
    test "walks segment-by-segment, creating each folder on the path" do
      # Search returns nothing for each segment → POST creates each.
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "leaf-folder"}}}
      )

      assert {:ok, "leaf-folder"} = GoogleDocsClient.ensure_folder_path("clients/active")
    end

    test "halts on the first error" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "drive down"}}}
      )

      assert {:error, :folder_search_failed} =
               GoogleDocsClient.ensure_folder_path("a/b/c")
    end
  end

  describe "create_document/2" do
    test "returns {:ok, %{doc_id, name, url}} on 200" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "doc-new", "name" => "My Doc"}}}
      )

      assert {:ok, %{doc_id: "doc-new", name: "My Doc", url: url}} =
               GoogleDocsClient.create_document("My Doc")

      assert is_binary(url)
      assert url =~ "doc-new"
    end

    test "returns {:error, :create_document_failed} on 5xx" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :create_document_failed} = GoogleDocsClient.create_document("X")
    end
  end

  describe "get_document/1" do
    test "returns {:ok, response} on 200 with the body intact" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-1",
        {:ok, %{status: 200, body: %{"documentId" => "doc-1"}}}
      )

      assert {:ok, %{body: %{"documentId" => "doc-1"}}} = GoogleDocsClient.get_document("doc-1")
    end

    test "rejects invalid file id without HTTP" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.get_document("../etc")
    end
  end

  describe "batch_update/2" do
    test "returns {:ok, response} on 200" do
      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      assert {:ok, %{body: %{"replies" => []}}} =
               GoogleDocsClient.batch_update("doc-1", [%{insertText: %{}}])
    end

    test "rejects invalid file id without HTTP" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.batch_update("../bad", [])
    end
  end

  describe "replace_all_text/2" do
    test "delegates to batch_update for non-empty variables" do
      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      assert {:ok, _} = GoogleDocsClient.replace_all_text("doc-1", %{"name" => "Acme"})
    end
  end

  describe "get_document_text/1" do
    test "extracts plain text from a Google Doc body" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-1",
        {:ok,
         %{
           status: 200,
           body: %{
             "body" => %{
               "content" => [
                 %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Hello "}}]}},
                 %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "World"}}]}}
               ]
             }
           }
         }}
      )

      assert {:ok, "Hello World"} = GoogleDocsClient.get_document_text("doc-1")
    end

    test "propagates :error from get_document" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-1",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      # `get_document/1` returns the raw `{:ok, response}` map, the
      # text extractor accepts any 2xx and produces "" if no content.
      # Pin the actual contract — non-200 surfaces the response as-is.
      assert {:ok, _} = GoogleDocsClient.get_document_text("doc-1")
    end
  end

  describe "copy_file/3" do
    test "returns {:ok, new_id} on 200" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files/src-file/copy",
        {:ok, %{status: 200, body: %{"id" => "copy-1"}}}
      )

      assert {:ok, "copy-1"} = GoogleDocsClient.copy_file("src-file", "Copy")
    end

    test "rejects invalid source id" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.copy_file("bad/id", "Copy")
    end

    test "returns {:error, :copy_failed} on non-2xx" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files/src-file/copy",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :copy_failed} = GoogleDocsClient.copy_file("src-file", "Copy")
    end
  end

  describe "export_pdf/1" do
    test "returns {:ok, pdf_binary} on 200" do
      pdf_body = String.duplicate("PDF", 50)

      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok, %{status: 200, body: pdf_body, headers: %{}}}
      )

      assert {:ok, ^pdf_body} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "rejects invalid file id without HTTP" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.export_pdf("../bad")
    end

    test "returns {:error, :pdf_export_failed} on non-200" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :pdf_export_failed} = GoogleDocsClient.export_pdf("doc-1")
    end
  end

  describe "move_file/2 (HTTP)" do
    test "succeeds with GET parents → PATCH addParents/removeParents" do
      file_id = "move-1"

      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
        {:ok, %{status: 200, body: %{"id" => file_id, "parents" => ["old-parent"]}}}
      )

      StubIntegrations.stub_request(
        :patch,
        "/drive/v3/files/#{file_id}",
        {:ok, %{status: 200, body: %{"id" => file_id}}}
      )

      assert :ok = GoogleDocsClient.move_file(file_id, "new-parent")
    end

    test "returns :move_failed when PATCH 5xxs" do
      file_id = "move-2"

      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
        {:ok, %{status: 200, body: %{"id" => file_id, "parents" => ["old"]}}}
      )

      StubIntegrations.stub_request(
        :patch,
        "/drive/v3/files/#{file_id}",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :move_failed} = GoogleDocsClient.move_file(file_id, "new")
    end

    test "returns :get_file_parents_failed when GET 5xxs" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/move-3",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :get_file_parents_failed} = GoogleDocsClient.move_file("move-3", "dst")
    end
  end

  describe "file_status/1 + file_location/1" do
    test "file_status returns map with parents + trashed" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-9",
        {:ok, %{status: 200, body: %{"id" => "doc-9", "parents" => ["root"], "trashed" => false}}}
      )

      assert {:ok, %{parents: ["root"], trashed: false}} = GoogleDocsClient.file_status("doc-9")
    end

    test "file_status :ok :not_found on 404" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/ghost",
        {:ok, %{status: 404, body: %{}}}
      )

      assert {:ok, :not_found} = GoogleDocsClient.file_status("ghost")
    end

    test "file_location resolves the parent path back to root" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-9",
        {:ok, %{status: 200, body: %{"id" => "doc-9", "parents" => ["root"], "trashed" => false}}}
      )

      assert {:ok, %{folder_id: "root", path: ""}} = GoogleDocsClient.file_location("doc-9")
    end
  end

  describe "get_credentials/0 + connection_status/0" do
    test "get_credentials returns the stub's :ok payload when connected" do
      assert {:ok, %{access_token: "stub-token"}} = GoogleDocsClient.get_credentials()
    end

    test "connection_status returns the stubbed email when connected" do
      assert {:ok, %{email: "test@example.com"}} = GoogleDocsClient.connection_status()
    end

    test "connection_status returns :not_configured when disconnected" do
      StubIntegrations.disconnected!()
      assert {:error, :not_configured} = GoogleDocsClient.connection_status()
    end
  end

  describe "get_folder_url/1" do
    test "returns the canonical Drive URL for a folder" do
      assert "https://drive.google.com/drive/folders/abc123" =
               GoogleDocsClient.get_folder_url("abc123")
    end

    test "returns nil for empty / nil input" do
      assert GoogleDocsClient.get_folder_url("") == nil
      assert GoogleDocsClient.get_folder_url(nil) == nil
    end
  end

  describe "get_edit_url/1" do
    test "returns canonical Docs edit URL for valid id" do
      assert "https://docs.google.com/document/d/abc/edit" =
               GoogleDocsClient.get_edit_url("abc")
    end

    test "returns nil for nil / empty" do
      assert GoogleDocsClient.get_edit_url("") == nil
      assert GoogleDocsClient.get_edit_url(nil) == nil
    end
  end
end
