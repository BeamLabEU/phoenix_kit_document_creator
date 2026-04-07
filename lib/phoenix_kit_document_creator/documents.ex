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

  @module_key "document_creator"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ===========================================================================
  # Activity logging
  # ===========================================================================

  @doc "Log a manual user action to the activity feed."
  def log_manual_action(action, opts \\ []) do
    attrs = %{
      action: action,
      mode: "manual",
      actor_uuid: opts[:actor_uuid]
    }

    attrs =
      case opts[:metadata] do
        meta when is_map(meta) -> Map.put(attrs, :metadata, meta)
        _ -> attrs
      end

    log_activity(attrs)
  end

  defp log_activity(attrs) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
    end
  end

  # ===========================================================================
  # DB Listing (fast, no API calls)
  # ===========================================================================

  @doc "List templates from the local DB. Returns maps compatible with the LiveView."
  def list_templates_from_db do
    Template
    |> where([t], t.status in ["published", "lost", "unfiled"])
    |> where([t], not is_nil(t.google_doc_id))
    |> order_by([t], desc: t.updated_at)
    |> repo().all()
    |> Enum.map(&schema_to_file_map/1)
  end

  @doc "List documents from the local DB. Returns maps compatible with the LiveView."
  def list_documents_from_db do
    Document
    |> where([d], d.status in ["published", "lost", "unfiled"])
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
      "status" => Map.get(record, :status, "published"),
      "path" => Map.get(record, :path),
      "folder_id" => Map.get(record, :folder_id)
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
      Enum.each(
        drive_templates,
        &upsert_template_from_drive(&1, managed_location_attrs(:template))
      )

      Enum.each(
        drive_documents,
        &upsert_document_from_drive(&1, managed_location_attrs(:document))
      )

      drive_template_ids = MapSet.new(drive_templates, & &1["id"])
      drive_document_ids = MapSet.new(drive_documents, & &1["id"])

      template_changes = reconcile_status(Template, drive_template_ids)
      document_changes = reconcile_status(Document, drive_document_ids)

      log_activity(%{
        action: "sync.completed",
        mode: "auto",
        resource_type: "sync",
        metadata: %{
          "templates_synced" => length(drive_templates),
          "documents_synced" => length(drive_documents),
          "templates_lost" => length(template_changes[:lost] || []),
          "templates_trashed" => length(template_changes[:trashed] || []),
          "templates_unfiled" => length(template_changes[:unfiled] || []),
          "documents_lost" => length(document_changes[:lost] || []),
          "documents_trashed" => length(document_changes[:trashed] || []),
          "documents_unfiled" => length(document_changes[:unfiled] || [])
        }
      })

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
      on_conflict: {:replace, [:name, :status, :path, :folder_id, :updated_at]},
      conflict_target: {:unsafe_fragment, "(google_doc_id) WHERE google_doc_id IS NOT NULL"}
    )
  end

  @doc "Upsert a document record from a Google Drive file map."
  def upsert_document_from_drive(%{"id" => gid, "name" => name} = _file, extra_attrs \\ %{}) do
    attrs = Map.merge(%{google_doc_id: gid, name: name, status: "published"}, extra_attrs)

    %Document{}
    |> Document.sync_changeset(attrs)
    |> repo().insert(
      on_conflict: {:replace, [:name, :status, :path, :folder_id, :updated_at]},
      conflict_target: {:unsafe_fragment, "(google_doc_id) WHERE google_doc_id IS NOT NULL"}
    )
  end

  # ===========================================================================
  # Status reconciliation
  # ===========================================================================

  # Returns a map of status => [uuids] for logging purposes.
  defp reconcile_status(schema, drive_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    managed_location = managed_location(schema_type(schema))
    deleted_folder_id = deleted_folder_id(schema_type(schema))

    tracked_records =
      schema
      |> where([r], r.status in ["published", "lost", "unfiled"] and not is_nil(r.google_doc_id))
      |> select([r], {r.uuid, r.google_doc_id, r.folder_id})
      |> repo().all()

    grouped =
      Enum.group_by(
        tracked_records,
        fn {_uuid, gid, folder_id} ->
          classify_file(gid, folder_id, drive_ids, managed_location, deleted_folder_id)
        end,
        fn {uuid, _gid, _folder_id} -> uuid end
      )

    update_statuses(schema, Map.get(grouped, :published, []), "published", now)
    update_statuses(schema, Map.get(grouped, :lost, []), "lost", now)
    update_statuses(schema, Map.get(grouped, :trashed, []), "trashed", now)
    update_statuses(schema, Map.get(grouped, :unfiled, []), "unfiled", now)

    grouped
  end

  defp classify_file(gid, folder_id, drive_ids, managed_location, deleted_folder_id) do
    if MapSet.member?(drive_ids, gid) do
      :published
    else
      classify_by_api(gid, folder_id, managed_location, deleted_folder_id)
    end
  end

  defp classify_by_api(gid, folder_id, managed_location, deleted_folder_id) do
    case GoogleDocsClient.file_status(gid) do
      {:ok, %{trashed: true}} ->
        :trashed

      {:ok, %{parents: parents}} when is_list(parents) ->
        classify_by_location(parents, folder_id, managed_location, deleted_folder_id)

      _ ->
        :lost
    end
  end

  defp classify_by_location(parents, folder_id, managed_location, deleted_folder_id) do
    accepted_folder_id = folder_id || managed_location.folder_id

    cond do
      is_binary(deleted_folder_id) and deleted_folder_id in parents -> :trashed
      is_binary(accepted_folder_id) and accepted_folder_id in parents -> :published
      true -> :unfiled
    end
  end

  defp update_file_by_google_doc_id(google_doc_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Map.put_new(attrs, :updated_at, now)

    Template
    |> where([t], t.google_doc_id == ^google_doc_id)
    |> repo().update_all(set: Map.to_list(attrs))

    Document
    |> where([d], d.google_doc_id == ^google_doc_id)
    |> repo().update_all(set: Map.to_list(attrs))
  end

  defp update_statuses(_schema, [], _status, _now), do: :ok

  defp update_statuses(schema, uuids, status, now) do
    schema
    |> where([r], r.uuid in ^uuids)
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

  @doc """
  Create a blank template in the templates folder. Returns `{:ok, %{doc_id, name, url}}`.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  def create_template(name \\ "Untitled Template", opts \\ []) do
    case get_folder_ids() do
      %{templates_folder_id: id} when is_binary(id) ->
        case GoogleDocsClient.create_document(name, parent: id) do
          {:ok, %{doc_id: doc_id} = result} ->
            upsert_template_from_drive(
              %{"id" => doc_id, "name" => name},
              managed_location_attrs(:template)
            )

            log_activity(%{
              action: "template.created",
              mode: "manual",
              actor_uuid: opts[:actor_uuid],
              resource_type: "template",
              metadata: %{"name" => name, "google_doc_id" => doc_id}
            })

            {:ok, result}

          error ->
            error
        end

      _ ->
        {:error, :templates_folder_not_found}
    end
  end

  @doc """
  Create a blank document in the documents folder. Returns `{:ok, %{doc_id, name, url}}`.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  def create_document(name \\ "Untitled Document", opts \\ []) do
    case get_folder_ids() do
      %{documents_folder_id: id} when is_binary(id) ->
        case GoogleDocsClient.create_document(name, parent: id) do
          {:ok, %{doc_id: doc_id} = result} ->
            upsert_document_from_drive(
              %{"id" => doc_id, "name" => name},
              managed_location_attrs(:document)
            )

            log_activity(%{
              action: "document.created",
              mode: "manual",
              actor_uuid: opts[:actor_uuid],
              resource_type: "document",
              metadata: %{"name" => name, "google_doc_id" => doc_id}
            })

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
            status: "published",
            path: managed_location(:document).path,
            folder_id: managed_location(:document).folder_id
          })
          |> repo().insert()

          log_activity(%{
            action: "document.created_from_template",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "document",
            metadata: %{
              "name" => doc_name,
              "google_doc_id" => new_doc_id,
              "template_google_doc_id" => template_file_id,
              "template_uuid" => template_uuid,
              "variables_used" => Map.keys(variable_values)
            }
          })

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
  # Unfiled actions
  # ===========================================================================

  @doc """
  Move a file into the managed templates folder and classify it as a template.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  def move_to_templates(file_id, opts \\ []) when is_binary(file_id) do
    case reclassify_file(file_id, :template) do
      :ok ->
        log_activity(%{
          action: "file.reclassified",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "template",
          metadata: %{
            "google_doc_id" => file_id,
            "action" => "move_to_templates"
          }
        })

        :ok

      error ->
        error
    end
  end

  @doc """
  Move a file into the managed documents folder and classify it as a document.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  def move_to_documents(file_id, opts \\ []) when is_binary(file_id) do
    case reclassify_file(file_id, :document) do
      :ok ->
        log_activity(%{
          action: "file.reclassified",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "document",
          metadata: %{
            "google_doc_id" => file_id,
            "action" => "move_to_documents"
          }
        })

        :ok

      error ->
        error
    end
  end

  @doc """
  Persist the file's current parent folder as its accepted location.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  def set_correct_location(file_id, opts \\ []) when is_binary(file_id) do
    with {:ok, %{folder_id: folder_id, path: path, trashed: false}} <-
           GoogleDocsClient.file_location(file_id),
         {type, _record} <- find_file_record(file_id) do
      update_file_by_google_doc_id(file_id, %{
        status: "published",
        folder_id: folder_id,
        path: path
      })

      log_activity(%{
        action: "file.location_accepted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: to_string(type),
        metadata: %{
          "google_doc_id" => file_id,
          "folder_id" => folder_id,
          "path" => path
        }
      })

      :ok
    else
      {:ok, %{trashed: true}} -> {:error, :file_trashed}
      nil -> {:error, :not_found}
      {:error, _} = err -> err
      _ -> {:error, :not_found}
    end
  end

  defp reclassify_file(file_id, target_type) do
    location = managed_location(target_type)

    with %{folder_id: folder_id} when is_binary(folder_id) <- location,
         source_record <- find_file_record(file_id),
         true <- not is_nil(source_record),
         :ok <- GoogleDocsClient.move_file(file_id, folder_id) do
      persist_reclassified_record(source_record, target_type, location)
    else
      nil -> {:error, :not_found}
      %{} -> {:error, :folder_not_found}
      {:error, _} = err -> err
      _ -> {:error, :not_found}
    end
  end

  defp persist_reclassified_record({:template, record}, :template, location) do
    update_file_by_google_doc_id(
      record.google_doc_id,
      Map.merge(%{status: "published"}, Map.take(location, [:path, :folder_id]))
    )

    :ok
  end

  defp persist_reclassified_record({:document, record}, :document, location) do
    update_file_by_google_doc_id(
      record.google_doc_id,
      Map.merge(%{status: "published"}, Map.take(location, [:path, :folder_id]))
    )

    :ok
  end

  defp persist_reclassified_record({:template, record}, :document, location) do
    repo().transaction(fn ->
      upsert_document_from_drive(
        %{"id" => record.google_doc_id, "name" => record.name},
        location
        |> Map.take([:path, :folder_id])
        |> Map.put(:status, "published")
        |> Map.put(:thumbnail, record.thumbnail)
      )

      repo().delete(record)
    end)

    :ok
  end

  defp persist_reclassified_record({:document, record}, :template, location) do
    repo().transaction(fn ->
      upsert_template_from_drive(
        %{"id" => record.google_doc_id, "name" => record.name},
        location
        |> Map.take([:path, :folder_id])
        |> Map.put(:status, "published")
        |> Map.put(:thumbnail, record.thumbnail)
      )

      repo().delete(record)
    end)

    :ok
  end

  defp find_file_record(file_id) do
    case repo().get_by(Template, google_doc_id: file_id) do
      nil ->
        case repo().get_by(Document, google_doc_id: file_id) do
          nil -> nil
          record -> {:document, record}
        end

      record ->
        {:template, record}
    end
  end

  # ===========================================================================
  # Deleting (soft — moves to deleted folder)
  # ===========================================================================

  @doc """
  Move a document to the deleted/documents folder.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  def delete_document(file_id, opts \\ []) when is_binary(file_id) do
    case move_to_deleted_folder(file_id, :deleted_documents_folder_id) do
      :ok ->
        log_activity(%{
          action: "document.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "document",
          metadata: %{"google_doc_id" => file_id}
        })

        :ok

      error ->
        error
    end
  end

  @doc """
  Move a template to the deleted/templates folder.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  def delete_template(file_id, opts \\ []) when is_binary(file_id) do
    case move_to_deleted_folder(file_id, :deleted_templates_folder_id) do
      :ok ->
        log_activity(%{
          action: "template.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "template",
          metadata: %{"google_doc_id" => file_id}
        })

        :ok

      error ->
        error
    end
  end

  defp move_to_deleted_folder(file_id, folder_key) do
    with {:ok, folder_id} <- resolve_deleted_folder_id(folder_key),
         :ok <- GoogleDocsClient.move_file(file_id, folder_id) do
      update_file_by_google_doc_id(file_id, %{
        status: "trashed",
        folder_id: folder_id,
        path: deleted_folder_path(folder_key)
      })

      :ok
    end
  end

  defp resolve_deleted_folder_id(folder_key) do
    case get_folder_ids() do
      %{^folder_key => id} when is_binary(id) ->
        {:ok, id}

      _ ->
        case refresh_folders() do
          %{^folder_key => id} when is_binary(id) -> {:ok, id}
          _ -> {:error, :deleted_folder_not_found}
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

  @doc """
  Export a Google Doc to PDF. Returns `{:ok, pdf_binary}`.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  - `:name` — document name (for activity metadata)
  """
  def export_pdf(file_id, opts \\ []) when is_binary(file_id) do
    case GoogleDocsClient.export_pdf(file_id) do
      {:ok, pdf_binary} = result ->
        log_activity(%{
          action: "document.exported_pdf",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "document",
          metadata: %{
            "google_doc_id" => file_id,
            "name" => opts[:name],
            "size_bytes" => byte_size(pdf_binary)
          }
        })

        result

      error ->
        error
    end
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

  defp schema_type(Template), do: :template
  defp schema_type(Document), do: :document

  defp managed_location_attrs(type) do
    managed_location(type)
    |> Map.take([:path, :folder_id])
  end

  defp managed_location(:template) do
    ids = get_folder_ids()
    config = GoogleDocsClient.get_folder_config()

    %{
      path: join_path(config.templates_path, config.templates_name),
      folder_id: ids[:templates_folder_id]
    }
  end

  defp managed_location(:document) do
    ids = get_folder_ids()
    config = GoogleDocsClient.get_folder_config()

    %{
      path: join_path(config.documents_path, config.documents_name),
      folder_id: ids[:documents_folder_id]
    }
  end

  defp deleted_folder_id(:template), do: get_folder_ids()[:deleted_templates_folder_id]
  defp deleted_folder_id(:document), do: get_folder_ids()[:deleted_documents_folder_id]

  defp deleted_folder_path(:deleted_templates_folder_id) do
    config = GoogleDocsClient.get_folder_config()
    join_path(join_path(config.deleted_path, config.deleted_name), config.templates_name)
  end

  defp deleted_folder_path(:deleted_documents_folder_id) do
    config = GoogleDocsClient.get_folder_config()
    join_path(join_path(config.deleted_path, config.deleted_name), config.documents_name)
  end

  defp join_path("", name), do: name
  defp join_path(path, name), do: "#{path}/#{name}"

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
