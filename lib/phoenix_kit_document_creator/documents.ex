defmodule PhoenixKitDocumentCreator.Documents do
  @moduledoc """
  Context module for managing templates and documents via Google Drive.

  Google Drive is the single source of truth for file content. This module
  mirrors file metadata (name, google_doc_id, status, thumbnails, variables)
  to the local database for fast listing and audit tracking.

  Listing reads from the local DB. A background sync polls Google Drive
  and upserts records, marking files as "lost" if they disappear from Drive.
  """

  import Ecto.Query

  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Schemas.Document
  alias PhoenixKitDocumentCreator.Schemas.Template

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ===========================================================================
  # DB Listing (fast, no API calls)
  # ===========================================================================

  @doc "List templates from the local DB. Returns maps compatible with the LiveView."
  def list_templates_from_db do
    Template
    |> where([t], t.status in ["published", "lost"])
    |> where([t], not is_nil(t.google_doc_id))
    |> order_by([t], desc: t.updated_at)
    |> repo().all()
    |> Enum.map(&schema_to_file_map/1)
  end

  @doc "List documents from the local DB. Returns maps compatible with the LiveView."
  def list_documents_from_db do
    Document
    |> where([d], d.status in ["published", "lost"])
    |> where([d], not is_nil(d.google_doc_id))
    |> order_by([d], desc: d.updated_at)
    |> repo().all()
    |> Enum.map(&schema_to_file_map/1)
  end

  defp schema_to_file_map(record) do
    %{
      "id" => record.google_doc_id,
      "name" => record.name,
      "modifiedTime" =>
        if(record.updated_at, do: DateTime.to_iso8601(record.updated_at), else: nil),
      "status" => Map.get(record, :status, "published")
    }
  end

  # ===========================================================================
  # Thumbnails (DB cache)
  # ===========================================================================

  @doc "Load cached thumbnails from DB for a list of google_doc_ids."
  def load_cached_thumbnails(google_doc_ids) when is_list(google_doc_ids) do
    template_thumbs =
      Template
      |> where([t], t.google_doc_id in ^google_doc_ids and not is_nil(t.thumbnail))
      |> select([t], {t.google_doc_id, t.thumbnail})
      |> repo().all()

    document_thumbs =
      Document
      |> where([d], d.google_doc_id in ^google_doc_ids and not is_nil(d.thumbnail))
      |> select([d], {d.google_doc_id, d.thumbnail})
      |> repo().all()

    Map.new(template_thumbs ++ document_thumbs)
  end

  def load_cached_thumbnails(_), do: %{}

  @doc "Persist a thumbnail data URI to the DB by google_doc_id."
  def persist_thumbnail(google_doc_id, data_uri) when is_binary(google_doc_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Template
      |> where([t], t.google_doc_id == ^google_doc_id)
      |> repo().update_all(set: [thumbnail: data_uri, updated_at: now])

    if count == 0 do
      Document
      |> where([d], d.google_doc_id == ^google_doc_id)
      |> repo().update_all(set: [thumbnail: data_uri, updated_at: now])
    end

    :ok
  end

  # ===========================================================================
  # Sync from Google Drive
  # ===========================================================================

  @doc """
  Sync local DB with Google Drive.

  Fetches file lists from both Drive folders, upserts all found files,
  marks DB records as "lost" if their google_doc_id is no longer in Drive,
  and recovers "lost" records that reappear.
  """
  def sync_from_drive do
    with %{templates_folder_id: tid, documents_folder_id: did}
         when is_binary(tid) and is_binary(did) <- get_folder_ids(),
         {:ok, drive_templates} <- GoogleDocsClient.list_folder_files(tid),
         {:ok, drive_documents} <- GoogleDocsClient.list_folder_files(did) do
      Enum.each(drive_templates, &upsert_template_from_drive/1)
      Enum.each(drive_documents, &upsert_document_from_drive/1)

      drive_template_ids = MapSet.new(drive_templates, & &1["id"])
      drive_document_ids = MapSet.new(drive_documents, & &1["id"])

      reconcile_status(Template, drive_template_ids)
      reconcile_status(Document, drive_document_ids)

      :ok
    else
      _ -> {:error, :sync_failed}
    end
  end

  # ===========================================================================
  # Upsert from Drive
  # ===========================================================================

  @doc "Upsert a template record from a Google Drive file map."
  def upsert_template_from_drive(%{"id" => gid, "name" => name} = _file, extra_attrs \\ %{}) do
    attrs = Map.merge(%{google_doc_id: gid, name: name, status: "published"}, extra_attrs)

    %Template{}
    |> Template.sync_changeset(attrs)
    |> repo().insert(
      on_conflict: {:replace, [:name, :status, :updated_at]},
      conflict_target: :google_doc_id
    )
  end

  @doc "Upsert a document record from a Google Drive file map."
  def upsert_document_from_drive(%{"id" => gid, "name" => name} = _file, extra_attrs \\ %{}) do
    attrs = Map.merge(%{google_doc_id: gid, name: name, status: "published"}, extra_attrs)

    %Document{}
    |> Document.sync_changeset(attrs)
    |> repo().insert(
      on_conflict: {:replace, [:name, :status, :updated_at]},
      conflict_target: :google_doc_id
    )
  end

  # ===========================================================================
  # Status reconciliation
  # ===========================================================================

  defp reconcile_status(schema, drive_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Mark published records as "lost" if their google_doc_id is not in Drive
    published_records =
      schema
      |> where([r], r.status == "published" and not is_nil(r.google_doc_id))
      |> select([r], {r.uuid, r.google_doc_id})
      |> repo().all()

    lost_uuids =
      published_records
      |> Enum.reject(fn {_uuid, gid} -> MapSet.member?(drive_ids, gid) end)
      |> Enum.map(fn {uuid, _gid} -> uuid end)

    if lost_uuids != [] do
      schema
      |> where([r], r.uuid in ^lost_uuids)
      |> repo().update_all(set: [status: "lost", updated_at: now])
    end

    # Recover "lost" records that reappeared in Drive
    lost_records =
      schema
      |> where([r], r.status == "lost" and not is_nil(r.google_doc_id))
      |> select([r], {r.uuid, r.google_doc_id})
      |> repo().all()

    recovered_uuids =
      lost_records
      |> Enum.filter(fn {_uuid, gid} -> MapSet.member?(drive_ids, gid) end)
      |> Enum.map(fn {uuid, _gid} -> uuid end)

    if recovered_uuids != [] do
      schema
      |> where([r], r.uuid in ^recovered_uuids)
      |> repo().update_all(set: [status: "published", updated_at: now])
    end
  end

  defp mark_status_by_google_doc_id(google_doc_id, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Template
    |> where([t], t.google_doc_id == ^google_doc_id)
    |> repo().update_all(set: [status: status, updated_at: now])

    Document
    |> where([d], d.google_doc_id == ^google_doc_id)
    |> repo().update_all(set: [status: status, updated_at: now])
  end

  # ===========================================================================
  # Listing (from Google Drive — used by sync)
  # ===========================================================================

  @doc "List all templates from the Google Drive templates folder."
  def list_templates do
    case get_folder_ids() do
      %{templates_folder_id: id} when is_binary(id) ->
        case GoogleDocsClient.list_folder_files(id) do
          {:ok, files} -> files
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc "List all documents from the Google Drive documents folder."
  def list_documents do
    case get_folder_ids() do
      %{documents_folder_id: id} when is_binary(id) ->
        case GoogleDocsClient.list_folder_files(id) do
          {:ok, files} -> files
          _ -> []
        end

      _ ->
        []
    end
  end

  # ===========================================================================
  # Creating
  # ===========================================================================

  @doc "Create a blank template in the templates folder. Returns `{:ok, %{doc_id, name, url}}`."
  def create_template(name \\ "Untitled Template") do
    case get_folder_ids() do
      %{templates_folder_id: id} when is_binary(id) ->
        case GoogleDocsClient.create_document(name, parent: id) do
          {:ok, %{doc_id: doc_id} = result} ->
            upsert_template_from_drive(%{"id" => doc_id, "name" => name})
            {:ok, result}

          error ->
            error
        end

      _ ->
        {:error, :templates_folder_not_found}
    end
  end

  @doc "Create a blank document in the documents folder. Returns `{:ok, %{doc_id, name, url}}`."
  def create_document(name \\ "Untitled Document") do
    case get_folder_ids() do
      %{documents_folder_id: id} when is_binary(id) ->
        case GoogleDocsClient.create_document(name, parent: id) do
          {:ok, %{doc_id: doc_id} = result} ->
            upsert_document_from_drive(%{"id" => doc_id, "name" => name})
            {:ok, result}

          error ->
            error
        end

      _ ->
        {:error, :documents_folder_not_found}
    end
  end

  @doc """
  Create a document from a template by copying and filling variables.

  1. Copies the template Google Doc to the documents folder
  2. Replaces all `{{variable}}` placeholders with values
  3. Persists the document record with variable_values and template link
  4. Returns `{:ok, %{doc_id, url}}`
  """
  def create_document_from_template(template_file_id, variable_values, opts \\ []) do
    doc_name = Keyword.get(opts, :name, "New Document")

    case get_folder_ids() do
      %{documents_folder_id: folder_id} when is_binary(folder_id) ->
        with {:ok, new_doc_id} <-
               GoogleDocsClient.copy_file(template_file_id, doc_name, parent: folder_id),
             {:ok, _} <- GoogleDocsClient.replace_all_text(new_doc_id, variable_values) do
          # Look up the template's DB uuid by its google_doc_id
          template_uuid = get_template_uuid_by_google_doc_id(template_file_id)

          # Persist document with variable values and template link
          %Document{}
          |> Document.creation_changeset(%{
            name: doc_name,
            google_doc_id: new_doc_id,
            template_uuid: template_uuid,
            variable_values: variable_values,
            status: "published"
          })
          |> repo().insert()

          {:ok, %{doc_id: new_doc_id, url: GoogleDocsClient.get_edit_url(new_doc_id)}}
        end

      _ ->
        {:error, :documents_folder_not_found}
    end
  end

  defp get_template_uuid_by_google_doc_id(google_doc_id) do
    Template
    |> where([t], t.google_doc_id == ^google_doc_id)
    |> select([t], t.uuid)
    |> repo().one()
  end

  # ===========================================================================
  # Deleting (soft — moves to deleted folder)
  # ===========================================================================

  @doc "Move a document to the deleted/documents folder."
  def delete_document(file_id) when is_binary(file_id) do
    move_to_deleted_folder(file_id, :deleted_documents_folder_id)
  end

  @doc "Move a template to the deleted/templates folder."
  def delete_template(file_id) when is_binary(file_id) do
    move_to_deleted_folder(file_id, :deleted_templates_folder_id)
  end

  defp move_to_deleted_folder(file_id, folder_key) do
    folder_id =
      case get_folder_ids() do
        %{^folder_key => id} when is_binary(id) -> id
        _ -> nil
      end

    # If folder ID is missing, re-discover (creates folders if needed) and retry
    folder_id =
      if folder_id do
        folder_id
      else
        case refresh_folders() do
          %{^folder_key => id} when is_binary(id) -> id
          _ -> nil
        end
      end

    case folder_id do
      nil ->
        {:error, :deleted_folder_not_found}

      id ->
        case GoogleDocsClient.move_file(file_id, id) do
          :ok ->
            mark_status_by_google_doc_id(file_id, "trashed")
            :ok

          error ->
            error
        end
    end
  end

  # ===========================================================================
  # Variables
  # ===========================================================================

  @doc "Detect `{{ variables }}` in a Google Doc's text content."
  def detect_variables(file_id) when is_binary(file_id) do
    case GoogleDocsClient.get_document_text(file_id) do
      {:ok, text} ->
        vars = PhoenixKitDocumentCreator.Variable.extract_variables(text)

        # Persist variable definitions to the template record
        var_defs =
          PhoenixKitDocumentCreator.Variable.build_definitions(vars)
          |> Enum.map(&Map.from_struct/1)

        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Template
        |> where([t], t.google_doc_id == ^file_id)
        |> repo().update_all(set: [variables: var_defs, updated_at: now])

        {:ok, vars}

      {:error, _} = err ->
        err
    end
  end

  # ===========================================================================
  # PDF Export
  # ===========================================================================

  @doc "Export a Google Doc to PDF. Returns `{:ok, pdf_binary}`."
  def export_pdf(file_id) when is_binary(file_id) do
    GoogleDocsClient.export_pdf(file_id)
  end

  # ===========================================================================
  # Thumbnails
  # ===========================================================================

  @doc """
  Fetch thumbnails for a list of Drive files asynchronously.

  Spawns a task per file that sends `{:thumbnail_result, file_id, data_uri}`
  back to the caller. Also persists thumbnails to the DB.
  """
  def fetch_thumbnails_async(files, caller_pid) when is_list(files) do
    Enum.each(files, fn file ->
      Task.start(fn -> fetch_and_notify_thumbnail(file["id"], caller_pid) end)
    end)
  end

  defp fetch_and_notify_thumbnail(file_id, caller_pid) do
    case GoogleDocsClient.fetch_thumbnail(file_id) do
      {:ok, data_uri} ->
        persist_thumbnail(file_id, data_uri)
        send(caller_pid, {:thumbnail_result, file_id, data_uri})

      _ ->
        :ok
    end
  end

  # ===========================================================================
  # Folders
  # ===========================================================================

  @doc "Get the folder IDs (auto-discovers if not cached)."
  def get_folder_ids do
    GoogleDocsClient.get_folder_ids()
  end

  @doc "Re-discover folder IDs from Drive."
  def refresh_folders do
    GoogleDocsClient.discover_folders()
  end

  @doc "Get the Google Drive URL for the templates folder."
  def templates_folder_url do
    case get_folder_ids() do
      %{templates_folder_id: id} when is_binary(id) -> GoogleDocsClient.get_folder_url(id)
      _ -> nil
    end
  end

  @doc "Get the Google Drive URL for the documents folder."
  def documents_folder_url do
    case get_folder_ids() do
      %{documents_folder_id: id} when is_binary(id) -> GoogleDocsClient.get_folder_url(id)
      _ -> nil
    end
  end
end
