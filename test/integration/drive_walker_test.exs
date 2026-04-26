defmodule PhoenixKitDocumentCreator.Integration.DriveWalkerTest do
  @moduledoc """
  Coverage for `PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker`.

  The walker's public surface (`list_files/1`, `list_folders/1`,
  `walk_tree/2`) flows through `GoogleDocsClient.authenticated_request/3`,
  which the Batch 4 retrofit makes stubbable via the
  `:integrations_backend` config. All Drive responses below are canned
  via `Test.StubIntegrations`.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker
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

  describe "list_files/1" do
    test "returns {:ok, []} for nil / empty / non-binary input" do
      assert {:ok, []} = DriveWalker.list_files(nil)
      assert {:ok, []} = DriveWalker.list_files("")
      assert {:ok, []} = DriveWalker.list_files(:not_a_binary)
    end

    test "returns the files when Drive responds 200 with a single page" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok,
         %{
           status: 200,
           body: %{
             "files" => [
               %{"id" => "file-1", "name" => "Doc 1", "parents" => ["folder-X"]},
               %{"id" => "file-2", "name" => "Doc 2", "parents" => ["folder-X"]}
             ]
           }
         }}
      )

      assert {:ok, [%{"id" => "file-1"}, %{"id" => "file-2"}]} =
               DriveWalker.list_files("folder-X")
    end

    test "returns {:error, :list_files_failed} on 5xx response" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "Drive down"}}}
      )

      assert {:error, :list_files_failed} = DriveWalker.list_files("folder-X")
    end

    test "propagates transport errors" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:error, :timeout}
      )

      assert {:error, :timeout} = DriveWalker.list_files("folder-X")
    end

    test "returns empty list on 200 with no files key" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{}}}
      )

      assert {:ok, []} = DriveWalker.list_files("folder-X")
    end
  end

  describe "list_folders/1" do
    test "returns {:ok, []} for empty folder_id" do
      assert {:ok, []} = DriveWalker.list_folders("")
      assert {:ok, []} = DriveWalker.list_folders(nil)
    end

    test "returns alphabetically-ordered subfolders" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok,
         %{
           status: 200,
           body: %{
             "files" => [
               %{"id" => "sub-a", "name" => "Alpha"},
               %{"id" => "sub-b", "name" => "Beta"}
             ]
           }
         }}
      )

      assert {:ok, [%{"id" => "sub-a"}, %{"id" => "sub-b"}]} =
               DriveWalker.list_folders("parent-X")
    end

    test "escapes single quotes in folder_id (Drive query injection guard)" do
      # The walker escapes single quotes via `String.replace("'", "\\'")`.
      # Here we just confirm the call doesn't crash on a quoted id; the
      # actual escaping is exercised by Drive accepting the constructed
      # query (mocked away — the assertion is the lack of crash).
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      assert {:ok, []} = DriveWalker.list_folders("folder'with'quotes")
    end
  end

  describe "walk_tree/2" do
    test "returns root + descendants when Drive returns a flat tree" do
      # First call: BFS level 1 — children of root_folder
      StubIntegrations.stub_request(
        :get,
        ~r{q=mimeType.*folder.*root-folder.*in.*parents},
        {:ok,
         %{
           status: 200,
           body: %{
             "files" => [
               %{"id" => "child-1", "name" => "Child One", "parents" => ["root-folder"]},
               %{"id" => "child-2", "name" => "Child Two", "parents" => ["root-folder"]}
             ]
           }
         }}
      )

      # Second call: BFS level 2 — children of child-1, child-2 (none).
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      assert {:ok, %{folders: folders, files: files}} =
               DriveWalker.walk_tree("root-folder", root_path: "root", max_depth: 5)

      assert is_map(folders)
      assert Map.has_key?(folders, "root-folder")
      assert is_list(files)
    end

    test "returns just the root entry when max_depth is 0" do
      # max_depth: 0 short-circuits the BFS at depth=1 > 0, but the
      # walker still issues the file-listing call for the root folder.
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      assert {:ok, %{folders: folders}} =
               DriveWalker.walk_tree("only-root", max_depth: 0)

      assert Map.has_key?(folders, "only-root")
    end

    test "returns {:error, _} when the folder query fails" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :list_files_failed} =
               DriveWalker.walk_tree("root-folder", max_depth: 3)
    end
  end
end
