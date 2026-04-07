defmodule PhoenixKitDocumentCreator.GoogleDocsClient do
  @moduledoc """
  Google Docs and Drive API client for the Document Creator module.

  This module provides **direct Google Drive and Docs API access** without
  touching the local database. Use it when you need raw Drive operations:
  creating files, listing folders, moving files, exporting PDFs, reading
  document content, and substituting template variables.

  For combined Drive + DB operations, use `PhoenixKitDocumentCreator.Documents`.

  ## Capabilities

  - **Folders**: `find_folder_by_name/2`, `create_folder/2`, `find_or_create_folder/2`,
    `ensure_folder_path/2`, `discover_folders/0`, `list_subfolders/1`
  - **Files**: `list_folder_files/1`, `move_file/2`, `copy_file/3`, `create_document/2`
  - **Docs**: `get_document/1`, `get_document_text/1`, `batch_update/2`, `replace_all_text/2`
  - **Export**: `export_pdf/1`, `fetch_thumbnail/1`
  - **Status**: `file_status/1`, `file_location/1`
  - **URLs**: `get_edit_url/1`, `get_folder_url/1`

  OAuth credentials and tokens are managed by `PhoenixKit.Integrations`
  under the `"google"` provider. Folder configuration is stored separately
  under the `"document_creator_folders"` settings key.
  """

  alias PhoenixKit.Integrations
  alias PhoenixKit.Settings

  @default_provider "google"
  @folder_settings_key "document_creator_folders"
  @settings_key "document_creator_settings"

  @docs_base "https://docs.googleapis.com/v1"
  @drive_base "https://www.googleapis.com/drive/v3"

  # ===========================================================================
  # Credentials (delegated to PhoenixKit.Integrations)
  # ===========================================================================

  @doc "Returns the active provider key, including connection slug if configured."
  def active_provider_key do
    case Settings.get_json_setting(@settings_key, %{}) do
      %{"google_connection" => key} when is_binary(key) and key != "" -> key
      _ -> @default_provider
    end
  end

  @doc "Get stored OAuth credentials via PhoenixKit.Integrations."
  def get_credentials do
    Integrations.get_credentials(active_provider_key())
  end

  @doc "Check if connected. Returns `{:ok, %{email: email}}` or `{:error, reason}`."
  def connection_status do
    case Integrations.get_integration(active_provider_key()) do
      {:ok, data} ->
        email =
          get_in(data, ["metadata", "connected_email"]) ||
            data["external_account_id"] ||
            "Unknown"

        {:ok, %{email: email}}

      {:error, _} = err ->
        err
    end
  end

  # ===========================================================================
  # Drive Folders
  # ===========================================================================

  @doc """
  Find a folder by name, optionally within a parent folder.
  Returns `{:ok, folder_id}` or `{:error, :not_found}`.
  """
  def find_folder_by_name(name, opts \\ []) do
    parent = Keyword.get(opts, :parent, "root")

    q =
      "name = '#{escape_query_value(name)}' and mimeType = 'application/vnd.google-apps.folder' and '#{escape_query_value(parent)}' in parents and trashed = false"

    case authenticated_request(:get, "#{@drive_base}/files",
           params: [q: q, fields: "files(id,name)", pageSize: 1]
         ) do
      {:ok, %{status: 200, body: %{"files" => [%{"id" => id} | _]}}} ->
        {:ok, id}

      {:ok, %{status: 200}} ->
        {:error, :not_found}

      {:ok, %{body: body}} ->
        {:error, "Folder search failed: #{inspect(body)}"}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Create a folder in Google Drive. Optionally specify a parent folder.
  Returns `{:ok, folder_id}`.
  """
  def create_folder(name, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    body = %{name: name, mimeType: "application/vnd.google-apps.folder"}
    body = if parent, do: Map.put(body, :parents, [parent]), else: body

    case authenticated_request(:post, "#{@drive_base}/files", json: body) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 -> {:ok, id}
      {:ok, %{body: body}} -> {:error, "Create folder failed: #{inspect(body)}"}
      {:error, _} = err -> err
    end
  end

  @doc """
  Find a folder by name, or create it if it doesn't exist.
  Optionally specify a parent folder.
  Returns `{:ok, folder_id}`.
  """
  def find_or_create_folder(name, opts \\ []) do
    case find_folder_by_name(name, opts) do
      {:ok, id} -> {:ok, id}
      {:error, :not_found} -> create_folder(name, opts)
      {:error, _} = err -> err
    end
  end

  @doc """
  Walk a path like "clients/active/templates", creating folders as needed.
  Returns `{:ok, leaf_folder_id}`.
  """
  def ensure_folder_path(path, opts \\ []) do
    parent = Keyword.get(opts, :parent, "root")
    segments = path |> String.split("/") |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(segments, {:ok, parent}, fn segment, {:ok, current_parent} ->
      case find_or_create_folder(segment, parent: current_parent) do
        {:ok, id} -> {:cont, {:ok, id}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc "Get configured folder paths and names from Settings, with defaults."
  def get_folder_config do
    creds = Settings.get_json_setting(@folder_settings_key, %{})

    %{
      templates_path: creds["folder_path_templates"] || "",
      templates_name: non_empty(creds["folder_name_templates"], "templates"),
      documents_path: creds["folder_path_documents"] || "",
      documents_name: non_empty(creds["folder_name_documents"], "documents"),
      deleted_path: creds["folder_path_deleted"] || "",
      deleted_name: non_empty(creds["folder_name_deleted"], "deleted")
    }
  end

  defp non_empty(val, _default) when is_binary(val) and val != "", do: val
  defp non_empty(_, default), do: default

  defp parse_cached_folder_ids(%{
         "templates_folder_id" => t,
         "documents_folder_id" => d,
         "deleted_templates_folder_id" => dt,
         "deleted_documents_folder_id" => dd
       })
       when is_binary(t) and t != "" and is_binary(d) and d != "" and is_binary(dt) and
              dt != "" and is_binary(dd) and dd != "" do
    {:ok,
     %{
       templates_folder_id: t,
       documents_folder_id: d,
       deleted_templates_folder_id: dt,
       deleted_documents_folder_id: dd
     }}
  end

  defp parse_cached_folder_ids(_), do: :miss

  defp build_full_path("", name), do: name
  defp build_full_path(path, name), do: "#{path}/#{name}"

  @doc """
  Discover templates, documents, and deleted folder IDs.
  Looks for folders by name in Drive root, creating them if they don't exist.
  Caches results in Settings.
  """
  def discover_folders do
    config = get_folder_config()

    templates_path = build_full_path(config.templates_path, config.templates_name)
    documents_path = build_full_path(config.documents_path, config.documents_name)
    deleted_path = build_full_path(config.deleted_path, config.deleted_name)

    # Resolve all four folder paths in parallel to minimize sequential API calls
    tasks = [
      Task.async(fn -> ensure_folder_path(templates_path) end),
      Task.async(fn -> ensure_folder_path(documents_path) end),
      Task.async(fn -> ensure_folder_path("#{deleted_path}/#{config.templates_name}") end),
      Task.async(fn -> ensure_folder_path("#{deleted_path}/#{config.documents_name}") end)
    ]

    [templates_id, documents_id, deleted_templates_id, deleted_documents_id] =
      tasks
      |> Task.await_many(30_000)
      |> Enum.map(fn
        {:ok, id} -> id
        _ -> nil
      end)

    # Save to folder settings
    folder_data = Settings.get_json_setting(@folder_settings_key, %{})

    updated =
      Map.merge(folder_data, %{
        "templates_folder_id" => templates_id,
        "documents_folder_id" => documents_id,
        "deleted_templates_folder_id" => deleted_templates_id,
        "deleted_documents_folder_id" => deleted_documents_id
      })

    Settings.update_json_setting_with_module(@folder_settings_key, updated, "document_creator")

    %{
      templates_folder_id: templates_id,
      documents_folder_id: documents_id,
      deleted_templates_folder_id: deleted_templates_id,
      deleted_documents_folder_id: deleted_documents_id
    }
  end

  @doc "Get cached folder IDs from Settings, or discover them."
  def get_folder_ids do
    case parse_cached_folder_ids(Settings.get_json_setting(@folder_settings_key, nil)) do
      {:ok, ids} -> ids
      :miss -> discover_folders()
    end
  end

  @doc "The Settings key used for folder configuration."
  def folder_settings_key, do: @folder_settings_key

  @doc "List subfolders within a parent folder. Returns `{:ok, [%{id, name}]}`."
  def list_subfolders(parent_id \\ "root") do
    q =
      "mimeType = 'application/vnd.google-apps.folder' and '#{escape_query_value(parent_id)}' in parents and trashed = false"

    case authenticated_request(:get, "#{@drive_base}/files",
           params: [q: q, fields: "files(id,name)", orderBy: "name", pageSize: 100]
         ) do
      {:ok, %{status: 200, body: %{"files" => files}}} -> {:ok, files}
      {:ok, %{status: 200}} -> {:ok, []}
      {:ok, %{body: body}} -> {:error, "List subfolders failed: #{inspect(body)}"}
      {:error, _} = err -> err
    end
  end

  @doc """
  List Google Docs in a Drive folder.
  Returns `{:ok, [%{id, name, modified_time, thumbnail_link}]}`.
  """
  def list_folder_files(folder_id) when is_binary(folder_id) and folder_id != "" do
    q =
      "'#{escape_query_value(folder_id)}' in parents and mimeType = 'application/vnd.google-apps.document' and trashed = false"

    case authenticated_request(:get, "#{@drive_base}/files",
           params: [
             q: q,
             fields: "files(id,name,modifiedTime,thumbnailLink)",
             orderBy: "modifiedTime desc",
             pageSize: 100
           ]
         ) do
      {:ok, %{status: 200, body: %{"files" => files}}} ->
        {:ok, files}

      {:ok, %{status: 200}} ->
        {:ok, []}

      {:ok, %{body: body}} ->
        {:error, "List files failed: #{inspect(body)}"}

      {:error, _} = err ->
        err
    end
  end

  def list_folder_files(_), do: {:ok, []}

  @doc "Get the Google Drive folder URL."
  def get_folder_url(folder_id) when is_binary(folder_id) and folder_id != "" do
    "https://drive.google.com/drive/folders/#{folder_id}"
  end

  def get_folder_url(_), do: nil

  @doc "Fetch Google Drive file metadata needed for sync classification."
  def file_status(file_id) when is_binary(file_id) and file_id != "" do
    case authenticated_request(:get, "#{@drive_base}/files/#{file_id}",
           params: [fields: "id,trashed,parents"]
         ) do
      {:ok, %{status: 200, body: %{"trashed" => trashed} = body}} when is_boolean(trashed) ->
        {:ok,
         %{
           trashed: trashed,
           parents: Map.get(body, "parents", [])
         }}

      {:ok, %{status: 404}} ->
        {:ok, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, _} = err ->
        err
    end
  end

  def file_status(_), do: {:error, :invalid_file_id}

  @doc "Resolve the current parent folder and path for a Drive file."
  def file_location(file_id) when is_binary(file_id) and file_id != "" do
    case file_status(file_id) do
      {:ok, %{parents: parents} = meta} ->
        folder_id = parents |> List.first() || "root"

        with {:ok, path} <- resolve_folder_path(folder_id) do
          {:ok, %{folder_id: folder_id, path: path, trashed: meta.trashed}}
        end

      {:ok, :not_found} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  def file_location(_), do: {:error, :invalid_file_id}

  defp resolve_folder_path("root"), do: {:ok, ""}

  defp resolve_folder_path(folder_id) do
    case authenticated_request(:get, "#{@drive_base}/files/#{folder_id}",
           params: [fields: "id,name,parents"]
         ) do
      {:ok, %{status: 200, body: %{"name" => name} = body}} ->
        parent_id = body |> Map.get("parents", []) |> List.first() || "root"

        with {:ok, parent_path} <- resolve_folder_path(parent_id) do
          {:ok, append_folder_path(parent_path, name)}
        end

      {:ok, %{status: 404}} ->
        {:error, :folder_not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp append_folder_path("", name), do: name
  defp append_folder_path(path, name), do: "#{path}/#{name}"

  # ===========================================================================
  # Google Docs API
  # ===========================================================================

  @doc "Create a new blank Google Doc in a specific folder."
  def create_document(title, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    # Create via Drive API so we can set the parent folder
    body = %{name: title, mimeType: "application/vnd.google-apps.document"}
    body = if parent, do: Map.put(body, :parents, [parent]), else: body

    case authenticated_request(:post, "#{@drive_base}/files", json: body) do
      {:ok, %{status: status, body: %{"id" => doc_id} = file}} when status in 200..299 ->
        {:ok, %{doc_id: doc_id, name: file["name"], url: get_edit_url(doc_id)}}

      {:ok, %{body: body}} ->
        {:error, "Create document failed: #{inspect(body)}"}

      {:error, _} = err ->
        err
    end
  end

  @doc "Read a Google Doc's full content."
  def get_document(doc_id) do
    authenticated_request(:get, "#{@docs_base}/documents/#{doc_id}")
  end

  @doc "Send a batchUpdate request to a Google Doc."
  def batch_update(doc_id, requests) when is_list(requests) do
    authenticated_request(:post, "#{@docs_base}/documents/#{doc_id}:batchUpdate",
      json: %{requests: requests}
    )
  end

  @doc """
  Replace all `{{variable}}` placeholders in a Google Doc.
  Keys are wrapped in `{{ }}` automatically.
  """
  def replace_all_text(doc_id, variables) when is_map(variables) do
    requests =
      Enum.map(variables, fn {key, value} ->
        %{
          replaceAllText: %{
            containsText: %{text: "{{#{key}}}", matchCase: true},
            replaceText: to_string(value)
          }
        }
      end)

    if requests == [], do: {:ok, %{}}, else: batch_update(doc_id, requests)
  end

  @doc "Extract plain text content from a Google Doc (for variable detection)."
  def get_document_text(doc_id) do
    case get_document(doc_id) do
      {:ok, %{body: body}} ->
        text =
          get_in(body, ["body", "content"])
          |> List.wrap()
          |> Enum.flat_map(fn el -> get_in(el, ["paragraph", "elements"]) || [] end)
          |> Enum.map_join(fn el -> get_in(el, ["textRun", "content"]) || "" end)

        {:ok, text}

      {:error, _} = err ->
        err
    end
  end

  # ===========================================================================
  # Google Drive API
  # ===========================================================================

  @doc "Move a file to a different folder in Google Drive."
  def move_file(file_id, to_folder_id) do
    with {:ok, fid} <- validate_file_id(file_id),
         {:ok, _tid} <- validate_file_id(to_folder_id) do
      do_move_file(fid, to_folder_id)
    end
  end

  defp do_move_file(file_id, to_folder_id) do
    case authenticated_request(:get, "#{@drive_base}/files/#{file_id}",
           params: [fields: "parents"]
         ) do
      {:ok, %{status: 200, body: %{"parents" => current_parents}}} ->
        remove = Enum.join(current_parents, ",")

        case authenticated_request(:patch, "#{@drive_base}/files/#{file_id}",
               params: [addParents: to_folder_id, removeParents: remove],
               json: %{}
             ) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, %{body: body}} -> {:error, "Move failed: #{inspect(body)}"}
          {:error, _} = err -> err
        end

      {:ok, %{body: body}} ->
        {:error, "Failed to get file parents: #{inspect(body)}"}

      {:error, _} = err ->
        err
    end
  end

  @doc "Copy a file in Google Drive. Returns the new file's ID."
  def copy_file(file_id, new_name, opts \\ []) do
    parent = Keyword.get(opts, :parent)
    body = %{name: new_name}
    body = if parent, do: Map.put(body, :parents, [parent]), else: body

    case authenticated_request(:post, "#{@drive_base}/files/#{file_id}/copy", json: body) do
      {:ok, %{status: status, body: %{"id" => new_id}}} when status in 200..299 -> {:ok, new_id}
      {:ok, %{body: body}} -> {:error, "Copy failed: #{inspect(body)}"}
      {:error, _} = err -> err
    end
  end

  @doc "Export a Google Doc as PDF. Returns `{:ok, pdf_binary}`."
  def export_pdf(doc_id) do
    case authenticated_request(:get, "#{@drive_base}/files/#{doc_id}/export",
           params: [mimeType: "application/pdf"]
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{body: body}} -> {:error, "PDF export failed: #{inspect(body)}"}
      {:error, _} = err -> err
    end
  end

  @doc "Fetch a document thumbnail as a base64 data URI via the Drive API."
  def fetch_thumbnail(doc_id) when is_binary(doc_id) and doc_id != "" do
    case authenticated_request(:get, "#{@drive_base}/files/#{doc_id}",
           params: [fields: "thumbnailLink"]
         ) do
      {:ok, %{status: 200, body: %{"thumbnailLink" => link}}} when is_binary(link) ->
        fetch_thumbnail_image(link)

      {:ok, %{status: 200}} ->
        {:error, :no_thumbnail}

      {:ok, %{body: body}} ->
        {:error, "Failed to get thumbnail link: #{inspect(body)}"}

      {:error, _} = err ->
        err
    end
  end

  def fetch_thumbnail(_), do: {:error, :no_doc_id}

  defp fetch_thumbnail_image(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type = extract_content_type(headers)

        {:ok, "data:#{content_type};base64,#{Base.encode64(body)}"}

      {:ok, %{status: status}} ->
        {:error, "Thumbnail fetch returned #{status}"}

      {:error, exception} ->
        {:error, "Thumbnail fetch failed: #{Exception.message(exception)}"}
    end
  end

  @doc "Get the edit URL for a Google Doc."
  def get_edit_url(doc_id) when is_binary(doc_id) and doc_id != "" do
    "https://docs.google.com/document/d/#{doc_id}/edit"
  end

  def get_edit_url(_), do: nil

  # ===========================================================================
  # Internal: Authenticated HTTP requests via PhoenixKit.Integrations
  # ===========================================================================

  defp authenticated_request(method, url, opts \\ []) do
    Integrations.authenticated_request(active_provider_key(), method, url, opts)
  end

  defp escape_query_value(value) do
    value |> to_string() |> String.replace("'", "\\'")
  end

  # Google Drive IDs are alphanumeric with hyphens and underscores.
  # Reject anything else to prevent URL path injection.
  @valid_file_id_pattern ~r/\A[\w-]+\z/

  @doc "Validate a Google Drive file/folder ID. Returns `{:ok, id}` or `{:error, :invalid_file_id}`."
  def validate_file_id(id) when is_binary(id) and id != "" do
    if Regex.match?(@valid_file_id_pattern, id), do: {:ok, id}, else: {:error, :invalid_file_id}
  end

  def validate_file_id(_), do: {:error, :invalid_file_id}

  # Extract content-type from Req response headers.
  # Req >= 0.5 returns headers as %{"content-type" => ["image/png"]}.
  defp extract_content_type(%{"content-type" => [v | _]}) do
    case String.split(v, ";") do
      [type | _] -> String.trim(type)
      _ -> "image/png"
    end
  end

  defp extract_content_type(_), do: "image/png"
end
