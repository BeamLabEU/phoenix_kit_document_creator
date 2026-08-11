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

    # Regression: without the status check a 404 error body flowed into the
    # append pipeline as a "document", document_end_index/1 read it as 1,
    # and the appended section landed at the top of the target document.
    test "returns {:error, :get_document_failed} on 404" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-404",
        {:ok, %{status: 404, body: %{"error" => %{"code" => 404, "message" => "Not found"}}}}
      )

      assert {:error, :get_document_failed} = GoogleDocsClient.get_document("doc-404")
    end

    test "returns {:error, :get_document_failed} on 5xx" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-500",
        {:ok, %{status: 500, body: %{"error" => %{"message" => "backend"}}}}
      )

      assert {:error, :get_document_failed} = GoogleDocsClient.get_document("doc-500")
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

    # Regression for the silent-batchUpdate bug: a 400 used to come back as
    # {:ok, resp} and every caller reported success on an unmodified doc.
    test "returns {:error, :batch_update_failed} on 400" do
      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok,
         %{status: 400, body: %{"error" => %{"code" => 400, "message" => "Invalid request"}}}}
      )

      assert {:error, :batch_update_failed} =
               GoogleDocsClient.batch_update("doc-1", [%{insertText: %{}}])
    end
  end

  describe "substitute_all_sections/3 — blank variable handling" do
    # Google's batchUpdate is atomic and rejects insertText with empty text,
    # so a single blank variable used to void every substitution in the
    # batch. A blank value must emit ONLY the deleteContentRange.
    test "a blank value clears its placeholder without a paired insertText" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "textRun" => %{"content" => "Hi {{a}} and {{b}}!\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-sub",
        {:ok, %{status: 200, body: doc}}
      )

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [%{position: 0, variable_values: %{"a" => "X", "b" => ""}, image_params: %{}}]
      ranges = %{0 => {1, 30}}

      assert :ok = GoogleDocsClient.substitute_all_sections("doc-sub", sections, ranges)

      batch_bodies =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            do: opts[:json].requests

      # One text-phase batch (no image fills → no image batch), in
      # descending index order: {{b}} (blank → delete only), then {{a}}
      # (delete + insert).
      assert [
               [
                 %{deleteContentRange: %{range: %{startIndex: 14, endIndex: 19}}},
                 %{deleteContentRange: %{range: %{startIndex: 4, endIndex: 9}}},
                 %{insertText: %{location: %{index: 4}, text: "X"}}
               ]
             ] = batch_bodies
    end
  end

  describe "substitute_all_sections/3 — section ranges after text substitution" do
    # Text substitution changes the document's length, moving every index that
    # follows an edit. The image phase re-fetches the document (so marker
    # indices are current) but used to match those fresh indices against the
    # PRE-substitution section ranges: in a multi-section compose, a later
    # section's `{{ images: name }}` marker drifts out of its own stale range
    # and is silently skipped — no images, no error.
    test "an image marker that shifted with the text is still filled" do
      # Section 0 holds a placeholder that SHRINKS by 10 units when filled
      # ("{{ customer }}" = 14 → "Acme" = 4); section 1 holds the image marker.
      before_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "textRun" => %{"content" => "Tellija: {{ customer }}\n"}}
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 25, "textRun" => %{"content" => "{{ images: photos }}\n"}}
                ]
              }
            }
          ]
        }
      }

      # What the second GET sees: section 0's text is now 10 units shorter, so
      # the marker sits at 15 instead of 25.
      after_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "textRun" => %{"content" => "Tellija: Acme\n"}}
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 15, "textRun" => %{"content" => "{{ images: photos }}\n"}}
                ]
              }
            }
          ]
        }
      }

      {:ok, calls} = Agent.start_link(fn -> 0 end)

      StubIntegrations.stub_request(:get, "/v1/documents/doc-shift", fn ->
        n = Agent.get_and_update(calls, fn n -> {n, n + 1} end)
        {:ok, %{status: 200, body: if(n == 0, do: before_doc, else: after_doc)}}
      end)

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [
        %{position: 0, variable_values: %{"customer" => "Acme"}, image_params: %{}},
        %{
          position: 1,
          variable_values: %{},
          image_params: %{
            "photos" => %{
              "kind" => "image_list",
              "columns" => 1,
              "width_px" => 300,
              "media" => [%{"uri" => "https://example.test/a.png"}]
            }
          }
        }
      ]

      ranges = %{0 => {1, 25}, 1 => {25, 46}}

      assert :ok = GoogleDocsClient.substitute_all_sections("doc-shift", sections, ranges)

      image_requests =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            request <- opts[:json].requests,
            Map.has_key?(request, :insertInlineImage),
            do: request

      assert [%{insertInlineImage: %{uri: "https://example.test/a.png"}}] = image_requests
    end
  end

  describe "shift_ranges/2" do
    test "moves boundaries by the net length change of earlier replacements" do
      # "{{ a }}" (7 units) → "LONGER" (6): −1, starting at index 3.
      replacements = [{"a", 3, 10, "LONGER"}]

      assert GoogleDocsClient.shift_ranges(%{0 => {1, 20}, 1 => {20, 40}}, replacements) ==
               %{0 => {1, 19}, 1 => {19, 39}}
    end

    test "leaves a boundary that precedes every replacement untouched" do
      replacements = [{"a", 30, 40, "x"}]

      assert GoogleDocsClient.shift_ranges(%{0 => {1, 20}, 1 => {20, 60}}, replacements) ==
               %{0 => {1, 20}, 1 => {20, 51}}
    end

    test "counts a replacement value in UTF-16 code units, not bytes" do
      # "õ" is 2 bytes in UTF-8 but 1 unit in Google's indexing; a 5-unit
      # placeholder replaced by "Kõiv" (4 units) shifts later text by −1.
      replacements = [{"a", 5, 10, "Kõiv"}]

      assert GoogleDocsClient.shift_ranges(%{0 => {1, 30}}, replacements) == %{0 => {1, 29}}
    end

    test "returns the ranges unchanged when nothing was replaced" do
      assert GoogleDocsClient.shift_ranges(%{0 => {1, 20}}, []) == %{0 => {1, 20}}
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

      # `get_document/1` checks the HTTP status (same contract as
      # `batch_update/2`) — a non-2xx no longer surfaces its error body
      # as a document, it fails loudly.
      assert {:error, :get_document_failed} = GoogleDocsClient.get_document_text("doc-1")
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
