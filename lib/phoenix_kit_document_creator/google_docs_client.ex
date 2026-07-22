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
  under the `"google"` provider. The module references the active
  connection by uuid via the `"google_connection"` field in the
  `"document_creator_settings"` row — `active_integration_uuid/0` is
  the resolver. Pre-uuid values (`"google"` / `"google:name"` strings)
  are auto-migrated to the matching integration row's uuid on first
  read; the rewritten setting then drives all subsequent dispatches.
  Folder configuration is stored separately under the
  `"document_creator_folders"` settings key.
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker

  @folder_settings_key "document_creator_folders"
  @settings_key "document_creator_settings"

  # Discovered-folder-ID cache keys inside the folder settings map. Dropped
  # whenever the folder config changes so IDs are re-discovered from the new
  # location. Exposed so callers (e.g. the settings LiveView) don't duplicate
  # this list.
  @cached_folder_id_keys ~w(
    templates_folder_id documents_folder_id
    deleted_templates_folder_id deleted_documents_folder_id
  )

  # Matches an RFC 4122-shaped UUID string (the storage row identifier
  # used by PhoenixKit.Integrations — currently UUIDv7, but this guard
  # only needs to discriminate "promoted to uuid" from legacy
  # `"google"` / `"google:name"` references; we don't enforce the
  # version digit). Anything that doesn't match here is legacy and
  # gets auto-migrated on first read.
  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @docs_base "https://docs.googleapis.com/v1"
  @drive_base "https://www.googleapis.com/drive/v3"
  @drive_upload_base "https://www.googleapis.com/upload/drive/v3"

  # All access to `PhoenixKit.Integrations` flows through this resolver so
  # tests can route the three call sites (get_credentials/1,
  # get_integration/1, authenticated_request/4) through a stub module
  # without external HTTP traffic. Production reads the default
  # (`PhoenixKit.Integrations`) when the config is absent — net diff is
  # one line per call site.
  defp integrations_backend do
    Application.get_env(
      :phoenix_kit_document_creator,
      :integrations_backend,
      PhoenixKit.Integrations
    )
  end

  # ===========================================================================
  # Credentials (delegated to PhoenixKit.Integrations)
  # ===========================================================================

  @doc """
  Returns the uuid of the active Google integration, or `nil` if none
  has been chosen.

  The settings value at `document_creator_settings.google_connection` is
  expected to be a UUIDv7 (the integration row's storage uuid). Older
  installs may have a legacy `"google"` or `"google:name"` string here;
  this function detects that, resolves it to the matching integration's
  uuid, rewrites the setting, and returns the uuid. Subsequent calls
  read the migrated value directly.
  """
  @spec active_integration_uuid() :: String.t() | nil
  def active_integration_uuid do
    case Settings.get_json_setting(@settings_key, %{}) do
      %{"google_connection" => stored} when is_binary(stored) ->
        if uuid?(stored), do: stored, else: migrate_legacy_connection(stored)

      _ ->
        nil
    end
  end

  @doc false
  # Public-but-not-API: shared across the lazy on-read path and the
  # boot-time sweep in `PhoenixKitDocumentCreator.migrate_legacy/0` so
  # the @uuid_pattern regex only lives here.
  @spec uuid?(term()) :: boolean()
  def uuid?(str), do: is_binary(str) and Regex.match?(@uuid_pattern, str)

  # Legacy `"google"` / `"google:name"` values predate the move to uuid-
  # based references. Look up the integration row matching the exact
  # `provider:name` shape, rewrite the setting to its uuid, and return
  # the uuid. If no row matches, null the setting and return nil so
  # callers see a clean "not configured" state.
  #
  # **Symmetric with `PhoenixKitDocumentCreator.migrate_legacy_connection_references/0`**:
  # both paths require an exact `provider:name` match. The previous
  # "any connected row for this provider" fallback was removed
  # because it silently picked between multi-account installs (a user
  # with `google:work` AND `google:personal` who had `"google"` in
  # settings would have one of them chosen arbitrarily). Failing
  # cleanly forces the admin to re-select via the integration picker.
  defp migrate_legacy_connection(legacy_key) do
    {provider_key, name} =
      case String.split(legacy_key, ":", parts: 2) do
        [p, n] when n != "" -> {p, n}
        [p] -> {p, "default"}
      end

    case integrations_backend().get_integration("#{provider_key}:#{name}") do
      {:ok, %{"name" => _} = data} ->
        case find_uuid_for_data(provider_key, data) do
          nil ->
            log_legacy_resolution_failed(legacy_key, :uuid_not_found)
            rewrite_setting(nil)

          uuid ->
            log_legacy_resolution_succeeded(legacy_key, uuid)
            rewrite_setting(uuid)
        end

      _ ->
        log_legacy_resolution_failed(legacy_key, :no_exact_match)
        rewrite_setting(nil)
    end
  end

  defp log_legacy_resolution_succeeded(legacy_key, uuid) do
    Logger.info("[GoogleDocsClient] migrated legacy '#{legacy_key}' → uuid=#{inspect(uuid)}")

    log_lazy_migration_activity(:reference_migrated, %{
      "old_value" => legacy_key,
      "new_uuid" => uuid
    })
  end

  defp log_legacy_resolution_failed(legacy_key, reason) do
    Logger.warning(
      "[GoogleDocsClient] cannot resolve legacy '#{legacy_key}': " <>
        "reason=#{inspect(reason)}; clearing setting"
    )

    log_lazy_migration_activity(:reference_migration_failed, %{
      "old_value" => legacy_key,
      "reason" => inspect(reason)
    })
  end

  defp log_lazy_migration_activity(action_atom, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "integration.legacy_migrated",
        module: "document_creator",
        mode: "auto",
        resource_type: "integration",
        metadata:
          Map.merge(metadata, %{
            "migration_kind" => Atom.to_string(action_atom),
            "actor_role" => "system",
            "trigger" => "lazy_on_read"
          })
      })
    end

    :ok
  rescue
    e ->
      Logger.warning(fn ->
        "[GoogleDocsClient] activity log failed during lazy legacy migration: " <>
          "kind=#{action_atom}, exception=#{inspect(e.__struct__)}"
      end)

      :ok
  end

  defp find_uuid_for_data(provider_key, data) do
    integrations_backend().list_connections(provider_key)
    |> Enum.find_value(fn %{uuid: uuid, name: name} ->
      if name == data["name"], do: uuid
    end)
  rescue
    # `find_uuid_for_data/2` runs from the lazy-read path
    # (`active_integration_uuid/0`), which fires on every request when
    # legacy data is still in `document_creator_settings`. A
    # transient backend failure (DB hiccup, integrations table
    # missing, sandbox owner exit) MUST NOT crash the request — the
    # downstream caller treats `nil` as "not found" and falls through
    # to the bare-provider list_connections scan or surfaces
    # `:not_configured` cleanly.
    e ->
      Logger.warning(fn ->
        "[GoogleDocsClient] find_uuid_for_data/2 failed: " <>
          "exception=#{inspect(e.__struct__)}"
      end)

      nil
  end

  defp rewrite_setting(uuid) do
    dc_settings = Settings.get_json_setting(@settings_key, %{})

    updated =
      case uuid do
        nil -> Map.delete(dc_settings, "google_connection")
        _ -> Map.put(dc_settings, "google_connection", uuid)
      end

    Settings.update_json_setting_with_module(@settings_key, updated, "document_creator")
    uuid
  rescue
    # Same crash-vector concern as `find_uuid_for_data/2` — the
    # rewrite is the persistence half of the lazy-read promotion. If
    # Settings can't write (DB down, table missing, write-permission
    # error), a request that just wanted to read credentials gets a
    # 500 instead. Swallow the failure and return the resolved uuid
    # anyway — the in-memory request still works; the next request
    # will retry the rewrite. Returning the original uuid keeps the
    # lazy promotion idempotent across attempts.
    e ->
      Logger.warning(fn ->
        "[GoogleDocsClient] rewrite_setting/1 failed: " <>
          "exception=#{inspect(e.__struct__)}, " <>
          "uuid=#{inspect(uuid)}"
      end)

      uuid
  end

  @doc "Get stored OAuth credentials via PhoenixKit.Integrations."
  @spec get_credentials() :: {:ok, map()} | {:error, atom()}
  def get_credentials do
    case active_integration_uuid() do
      nil -> {:error, :not_configured}
      uuid -> integrations_backend().get_credentials(uuid)
    end
  end

  @doc "Check if connected. Returns `{:ok, %{email: email}}` or `{:error, reason}`."
  @spec connection_status() :: {:ok, %{email: String.t()}} | {:error, atom()}
  def connection_status do
    case active_integration_uuid() do
      nil ->
        {:error, :not_configured}

      uuid ->
        case integrations_backend().get_integration(uuid) do
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
  end

  # ===========================================================================
  # Drive Folders
  # ===========================================================================

  @doc """
  Find a folder by name, optionally within a parent folder.
  Returns `{:ok, folder_id}` or `{:error, :not_found}`.
  """
  @spec find_folder_by_name(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_found | :folder_search_failed | term()}
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
        log_drive_error("folder search failed", body)
        {:error, :folder_search_failed}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Create a folder in Google Drive. Optionally specify a parent folder.
  Returns `{:ok, folder_id}`.
  """
  @spec create_folder(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :create_folder_failed | term()}
  def create_folder(name, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    body = %{name: name, mimeType: "application/vnd.google-apps.folder"}
    body = if parent, do: Map.put(body, :parents, [parent]), else: body

    case authenticated_request(:post, "#{@drive_base}/files", json: body) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 ->
        {:ok, id}

      {:ok, %{body: body}} ->
        log_drive_error("create folder failed", body)
        {:error, :create_folder_failed}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Find a folder by name, or create it if it doesn't exist.
  Optionally specify a parent folder.
  Returns `{:ok, folder_id}`.
  """
  @spec find_or_create_folder(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
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
  @spec ensure_folder_path(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
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
  @spec get_folder_config() :: map()
  def get_folder_config do
    creds = Settings.get_json_setting(@folder_settings_key, %{})

    %{
      root_path: creds["folder_path_root"] || "",
      root_name: non_empty(creds["folder_name_root"], ""),
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

  @doc "Compute the three Drive paths (templates, documents, deleted) given a folder config map."
  @spec resolved_folder_paths(map()) :: {String.t(), String.t(), String.t()}
  def resolved_folder_paths(config) do
    root_abs =
      if config.root_name != "" do
        build_full_path(config.root_path, config.root_name)
      else
        nil
      end

    prefix = fn path ->
      if root_abs, do: "#{root_abs}/#{path}", else: path
    end

    templates = prefix.(build_full_path(config.templates_path, config.templates_name))
    documents = prefix.(build_full_path(config.documents_path, config.documents_name))
    deleted = prefix.(build_full_path(config.deleted_path, config.deleted_name))

    {templates, documents, deleted}
  end

  @doc """
  Discover templates, documents, and deleted folder IDs.
  Looks for folders by name in Drive root, creating them if they don't exist.
  Caches results in Settings.
  """
  @spec discover_folders() :: %{
          templates_folder_id: String.t() | nil,
          documents_folder_id: String.t() | nil,
          deleted_templates_folder_id: String.t() | nil,
          deleted_documents_folder_id: String.t() | nil
        }
  def discover_folders do
    config = get_folder_config()

    {templates_path, documents_path, deleted_path} = resolved_folder_paths(config)

    # Resolve all four folder paths in parallel to minimize sequential API calls.
    #
    # `Task.Supervisor.async_stream_nolink/4` under `PhoenixKit.TaskSupervisor`
    # supersedes the previous `Task.async/1` shape. Two reasons:
    #
    # 1. **Caller-exit cleanup**: bare `Task.async/1` links the spawned task
    #    to the calling process. If the LV exits mid-await (admin closes
    #    the tab), `Task.await_many/2`'s timeout path is never reached
    #    and `Task.shutdown` doesn't run — orphans are blocked on the
    #    remote Drive call until the HTTP timeout fires. Under the
    #    supervisor with `:nolink`, the calling process exiting causes
    #    the supervisor to clean the children automatically.
    #
    # 2. **No more `catch :exit, _`**: `async_stream` reports per-task
    #    failure via `{:exit, reason}` tuples in the stream, so the
    #    timeout-vs-success branch is plain pattern matching.
    paths = [
      templates_path,
      documents_path,
      "#{deleted_path}/#{config.templates_name}",
      "#{deleted_path}/#{config.documents_name}"
    ]

    [templates_id, documents_id, deleted_templates_id, deleted_documents_id] =
      Task.Supervisor.async_stream_nolink(
        PhoenixKit.TaskSupervisor,
        paths,
        fn path -> ensure_folder_path(path) end,
        timeout: 30_000,
        on_timeout: :kill_task,
        ordered: true,
        max_concurrency: 4
      )
      |> Enum.map(fn
        {:ok, {:ok, id}} ->
          id

        {:ok, {:error, reason}} ->
          Logger.warning("Folder discovery failed: #{inspect(reason)}")
          nil

        {:exit, reason} ->
          Logger.error("Document Creator folder discovery failed: #{inspect(reason)}")
          nil
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
  @spec get_folder_ids() :: map()
  def get_folder_ids do
    case parse_cached_folder_ids(Settings.get_json_setting(@folder_settings_key, nil)) do
      {:ok, ids} -> ids
      :miss -> discover_folders()
    end
  end

  @doc "The Settings key used for folder configuration."
  @spec folder_settings_key() :: String.t()
  def folder_settings_key, do: @folder_settings_key

  @doc "Folder-settings keys holding discovered folder IDs (cleared on config change)."
  @spec cached_folder_id_keys() :: [String.t()]
  def cached_folder_id_keys, do: @cached_folder_id_keys

  @doc """
  Move the top-level Drive folders (templates, documents, deleted) into
  `root_folder_id`. For each folder the cached ID is tried first; when absent,
  the folder is located by name in the Drive root. Moving the deleted folder
  carries its sub-folders along automatically.

  Clears cached folder IDs on full success so they are re-discovered from the
  new location on next use.

  Returns `{:ok, %{moved: [labels], skipped: [labels]}}` or
  `{:error, [{label, reason}]}` if any move fails.
  """
  @spec migrate_folders_to_root(String.t()) ::
          {:ok, %{moved: [String.t()], skipped: [String.t()]}}
          | {:error, [{String.t(), term()}]}
  def migrate_folders_to_root(root_folder_id) do
    config = get_folder_config()
    folder_data = Settings.get_json_setting(@folder_settings_key, %{})

    candidates = [
      {"templates", config.templates_name, folder_data["templates_folder_id"]},
      {"documents", config.documents_name, folder_data["documents_folder_id"]},
      {"deleted", config.deleted_name, nil}
    ]

    results = Enum.map(candidates, &migrate_folder_candidate(&1, root_folder_id))

    failures = for {:error, f} <- results, do: f
    moved = for {:ok, label} <- results, do: label
    skipped = for {:skip, label} <- results, do: label

    if failures == [] do
      clear_cached_folder_ids(folder_data)
      {:ok, %{moved: moved, skipped: skipped}}
    else
      Logger.error("Document Creator folder migration failed: #{inspect(failures)}")
      {:error, failures}
    end
  end

  defp migrate_folder_candidate({label, name, cached_id}, root_folder_id) do
    case resolve_migration_folder_id(name, cached_id) do
      {:ok, folder_id} -> move_migration_folder(folder_id, root_folder_id, label)
      {:error, :not_found} -> {:skip, label}
      {:error, reason} -> {:error, {label, reason}}
    end
  end

  defp resolve_migration_folder_id(name, cached_id) do
    cond do
      is_binary(cached_id) and cached_id != "" -> {:ok, cached_id}
      name != "" -> find_folder_by_name(name, parent: "root")
      true -> {:error, :not_found}
    end
  end

  defp move_migration_folder(folder_id, root_folder_id, label) do
    case move_file(folder_id, root_folder_id) do
      :ok -> {:ok, label}
      {:error, reason} -> {:error, {label, reason}}
    end
  end

  defp clear_cached_folder_ids(folder_data) do
    updated = Map.drop(folder_data, @cached_folder_id_keys)
    Settings.update_json_setting_with_module(@folder_settings_key, updated, "document_creator")
  end

  @doc """
  List subfolders within a parent folder (non-recursive, fully paginated).
  Returns `{:ok, [%{"id" => ..., "name" => ...}]}`.
  """
  @spec list_subfolders(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_subfolders(parent_id \\ "root"), do: DriveWalker.list_folders(parent_id)

  @doc """
  List Google Docs directly in a Drive folder (non-recursive, fully paginated).

  Returns `{:ok, [%{"id" => ..., "name" => ..., "modifiedTime" => ..., "thumbnailLink" => ..., "parents" => [...]}]}`.

  For recursive traversal across subfolders, use
  `PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker.walk_tree/2`.
  """
  @spec list_folder_files(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_folder_files(folder_id), do: DriveWalker.list_files(folder_id)

  @doc "Get the Google Drive folder URL."
  @spec get_folder_url(term()) :: String.t() | nil
  def get_folder_url(folder_id) when is_binary(folder_id) and folder_id != "" do
    "https://drive.google.com/drive/folders/#{folder_id}"
  end

  def get_folder_url(_), do: nil

  @doc "Fetch Google Drive file metadata needed for sync classification."
  @spec file_status(term()) ::
          {:ok, %{trashed: boolean(), parents: [String.t()]}}
          | {:ok, :not_found}
          | {:error, :invalid_file_id | term()}
  def file_status(file_id) when is_binary(file_id) and file_id != "" do
    with {:ok, fid} <- validate_file_id(file_id) do
      case authenticated_request(:get, "#{@drive_base}/files/#{fid}",
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
  end

  def file_status(_), do: {:error, :invalid_file_id}

  @doc "Resolve the current parent folder and path for a Drive file."
  @spec file_location(term()) ::
          {:ok, %{folder_id: String.t(), path: String.t(), trashed: boolean()}}
          | {:error, :invalid_file_id | :not_found | term()}
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

  @max_folder_depth 20

  defp resolve_folder_path(folder_id), do: resolve_folder_path(folder_id, @max_folder_depth)

  defp resolve_folder_path("root", _depth), do: {:ok, ""}
  defp resolve_folder_path(_folder_id, 0), do: {:error, :max_depth_exceeded}

  defp resolve_folder_path(folder_id, depth) do
    case authenticated_request(:get, "#{@drive_base}/files/#{folder_id}",
           params: [fields: "id,name,parents"]
         ) do
      {:ok, %{status: 200, body: %{"name" => name} = body}} ->
        parent_id = body |> Map.get("parents", []) |> List.first() || "root"

        with {:ok, parent_path} <- resolve_folder_path(parent_id, depth - 1) do
          {:ok, build_full_path(parent_path, name)}
        end

      {:ok, %{status: 404}} ->
        {:error, :folder_not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ===========================================================================
  # Google Docs API
  # ===========================================================================

  @doc "Create a new blank Google Doc in a specific folder."
  @spec create_document(String.t(), keyword()) ::
          {:ok, %{doc_id: String.t(), name: String.t(), url: String.t() | nil}}
          | {:error, :create_document_failed | term()}
  def create_document(title, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    # Create via Drive API so we can set the parent folder
    body = %{name: title, mimeType: "application/vnd.google-apps.document"}
    body = if parent, do: Map.put(body, :parents, [parent]), else: body

    case authenticated_request(:post, "#{@drive_base}/files", json: body) do
      {:ok, %{status: status, body: %{"id" => doc_id} = file}} when status in 200..299 ->
        {:ok, %{doc_id: doc_id, name: file["name"], url: get_edit_url(doc_id)}}

      {:ok, %{body: body}} ->
        log_drive_error("create document failed", body)
        {:error, :create_document_failed}

      {:error, _} = err ->
        err
    end
  end

  @doc "Read a Google Doc's full content."
  @spec get_document(String.t()) :: {:ok, map()} | {:error, term()}
  def get_document(doc_id) do
    with {:ok, fid} <- validate_file_id(doc_id) do
      authenticated_request(:get, "#{@docs_base}/documents/#{fid}")
    end
  end

  @doc "Send a batchUpdate request to a Google Doc."
  @spec batch_update(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def batch_update(doc_id, requests) when is_list(requests) do
    with {:ok, fid} <- validate_file_id(doc_id) do
      case authenticated_request(:post, "#{@docs_base}/documents/#{fid}:batchUpdate",
             json: %{requests: requests}
           ) do
        {:ok, %{status: status} = resp} when status in 200..299 ->
          {:ok, resp}

        {:ok, %{body: body}} ->
          log_drive_error("batchUpdate failed", body)
          {:error, :batch_update_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Replace all `{{variable}}` placeholders in a Google Doc.
  Keys are wrapped in `{{ }}` automatically.
  """
  @spec replace_all_text(String.t(), map()) :: {:ok, map()} | {:error, term()}
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
  @spec get_document_text(String.t()) :: {:ok, String.t()} | {:error, term()}
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

  @doc """
  Scans a `documents.get` response for image tag occurrences.

  Returns a flat list of `%{name, start_index, end_index}` covering every
  occurrence in body content, headers, footers, and table cells, restricted
  to the names supplied.

  **Offset note:** `Regex.scan(..., return: :index)` returns byte offsets;
  Google Docs `startIndex` counts UTF-16 code units. The implementation
  converts byte offsets to UTF-16 code-unit counts via
  `:unicode.characters_to_binary/3` so supplementary-plane codepoints
  (emoji, rare CJK) are counted as the two units a surrogate pair occupies.
  """
  @spec find_image_tag_ranges(map(), [String.t()]) ::
          [%{name: String.t(), start_index: integer(), end_index: integer()}]
  def find_image_tag_ranges(%{} = doc, names) when is_list(names) do
    names_set = MapSet.new(names)

    body_blocks = get_in(doc, ["body", "content"]) || []

    header_blocks =
      doc
      |> Map.get("headers", %{})
      |> Map.values()
      |> Enum.flat_map(&Map.get(&1, "content", []))

    footer_blocks =
      doc
      |> Map.get("footers", %{})
      |> Map.values()
      |> Enum.flat_map(&Map.get(&1, "content", []))

    (body_blocks ++ header_blocks ++ footer_blocks)
    |> Enum.flat_map(&walk_block/1)
    |> Enum.flat_map(&extract_tag_ranges(&1, names_set))
  end

  defp walk_block(%{"paragraph" => %{"elements" => elements}}), do: elements

  defp walk_block(%{"table" => %{"tableRows" => rows}}) do
    Enum.flat_map(rows, fn %{"tableCells" => cells} ->
      Enum.flat_map(cells, fn %{"content" => content} ->
        Enum.flat_map(content, &walk_block/1)
      end)
    end)
  end

  defp walk_block(_), do: []

  @image_tag_regex ~r/\{\{\s*(image|images)\s*:\s*(\w+)\s*\}\}/

  defp extract_tag_ranges(
         %{"textRun" => %{"content" => content}, "startIndex" => base},
         names_set
       ) do
    Regex.scan(@image_tag_regex, content, return: :index)
    |> Enum.flat_map(&match_to_range(&1, content, base, names_set))
  end

  defp extract_tag_ranges(_, _), do: []

  defp match_to_range(
         [{full_byte_start, full_byte_len}, _keyword_pos, {name_byte_start, name_byte_len}],
         content,
         base,
         names_set
       ) do
    # `Regex.scan` with `return: :index` yields byte offsets. Google Docs
    # `startIndex` counts UTF-16 code units (one per BMP codepoint, two per
    # supplementary). Convert the prefix-and-match bytes to UTF-16 length
    # so supplementary-plane codepoints (emoji, rare CJK) contribute the
    # surrogate-pair pair of code units they occupy in the doc index.
    full_u16_start = content |> binary_part(0, full_byte_start) |> utf16_units()
    full_u16_len = content |> binary_part(full_byte_start, full_byte_len) |> utf16_units()
    name = binary_part(content, name_byte_start, name_byte_len)

    if MapSet.member?(names_set, name) do
      [
        %{
          name: name,
          start_index: base + full_u16_start,
          end_index: base + full_u16_start + full_u16_len
        }
      ]
    else
      []
    end
  end

  defp match_to_range(_, _, _, _), do: []

  # Number of UTF-16 code units the given UTF-8 binary occupies — i.e. the
  # `startIndex` arithmetic unit Google Docs uses. Supplementary-plane
  # codepoints (most emoji, rare CJK) contribute two units (a surrogate
  # pair); BMP codepoints contribute one.
  defp utf16_units(binary) do
    binary
    |> :unicode.characters_to_binary(:utf8, :utf16)
    |> byte_size()
    |> div(2)
  end

  # Google Docs `Unit` enum accepts only `PT` or `UNIT_UNSPECIFIED`; 1 px = 0.75 pt
  # (96 dpi web → 72 dpi PostScript). Earlier versions sent `unit: "EMU"`, which
  # Google rejects with `INVALID_ARGUMENT` (`google.apps.docs.v1.Unit`), so every
  # `insertInlineImage` batch failed.
  @px_to_pt 0.75
  @image_gap_pt 8.0
  @default_content_width_pt 468.0
  @max_columns 4

  @doc """
  Page content width in points = pageSize.width − marginLeft − marginRight.
  Falls back to 468pt (US Letter with 1" margins) if anything is missing.
  """
  def content_width_pt(document) when is_map(document) do
    ds = Map.get(document, "documentStyle") || %{}
    width = magnitude(get_in(ds, ["pageSize", "width"]))
    margin_l = magnitude(Map.get(ds, "marginLeft")) || 72.0
    margin_r = magnitude(Map.get(ds, "marginRight")) || 72.0

    case width do
      nil -> @default_content_width_pt
      w -> w - margin_l - margin_r
    end
  end

  defp magnitude(%{"magnitude" => m}) when is_number(m), do: m * 1.0
  defp magnitude(_), do: nil

  @doc """
  Per-image width in points for N columns sharing `content_width_pt`.
  """
  def image_width_for_columns(content_width_pt, columns)
      when is_number(content_width_pt) do
    n = columns |> max(1) |> min(@max_columns)
    (content_width_pt - @image_gap_pt * (n - 1)) / n
  end

  @doc """
  Phase A — emits batchUpdate requests that delete the placeholder range and
  create a Google Docs table at its start index. After a doc re-fetch,
  `fill_table_cells/3` populates the table.
  """
  def table_image_inserts(%{start_index: s, end_index: e}, media, opts)
      when is_list(media) do
    cols = (opts[:columns] || 1) |> max(1) |> min(@max_columns)
    rows = (length(media) / cols) |> Float.ceil() |> trunc() |> max(1)

    [
      %{"deleteContentRange" => %{"range" => %{"startIndex" => s, "endIndex" => e}}},
      %{"insertTable" => %{"rows" => rows, "columns" => cols, "location" => %{"index" => s}}}
    ]
  end

  @doc """
  Phase B — emits insertInlineImage requests for each cell, last-first so
  earlier inserts don't shift later indices. One image per cell; extra cells
  beyond the media list are ignored.
  """
  def fill_table_cells(cells, media, %{image_width_pt: w_pt})
      when is_list(cells) do
    cells
    |> Enum.zip(media)
    |> Enum.reverse()
    |> Enum.map(fn {%{insert_index: idx}, media_item} ->
      uri = Map.get(media_item, :uri) || Map.get(media_item, "uri")
      src_w = Map.get(media_item, :width_px) || Map.get(media_item, "width_px")
      src_h = Map.get(media_item, :height_px) || Map.get(media_item, "height_px")

      # scale_height mixes units here: target is PT, src dims are PX. The
      # resulting height is w_pt * (h_px / w_px), which is numerically in PT
      # because the PX ratio cancels. Google Docs renders the correct aspect;
      # absolute height value is not in PT when src dims are absent (falls back
      # to w_pt, a square).
      scaled_h_pt = scale_height(w_pt, src_w, src_h) || w_pt

      %{
        "insertInlineImage" => %{
          "location" => %{"index" => idx},
          "uri" => uri,
          "objectSize" => %{
            "width" => %{"magnitude" => w_pt * 1.0, "unit" => "PT"},
            "height" => %{"magnitude" => scaled_h_pt * 1.0, "unit" => "PT"}
          }
        }
      }
    end)
  end

  @doc """
  Identifies which of `tables_asc` (table elements from the re-fetched document,
  ascending by start index) are the tables Phase 1 just inserted, returning them
  in slot order.

  `pre_existing_starts` and `new_slot_starts` are start indices captured from the
  *pre-Phase-1* document. Phase 1's deletes/inserts shift the absolute indices of
  everything after a placeholder, so a startIndex set-difference misclassifies a
  pre-existing table located after a placeholder (its index moves and no longer
  matches the snapshot). Table *order* is never changed by inserts, though, so we
  reconstruct the pre/new interleaving from the original indices and read it off
  the post-Phase-1 tables positionally — robust regardless of where pre-existing
  tables sit relative to the placeholders.

  Returns `{:ok, new_tables}` aligned with `new_slot_starts` sorted ascending, or
  `:mismatch` when the table count doesn't line up (e.g. Phase 1 partially
  failed) so the caller can skip filling rather than fill the wrong tables.
  """
  @spec match_new_tables([map()], [non_neg_integer()], [non_neg_integer()]) ::
          {:ok, [map()]} | :mismatch
  def match_new_tables(tables_asc, pre_existing_starts, new_slot_starts) do
    pattern =
      (Enum.map(pre_existing_starts, &{&1, :pre}) ++
         Enum.map(new_slot_starts, &{&1, :new}))
      |> Enum.sort_by(fn {idx, _tag} -> idx end)
      |> Enum.map(fn {_idx, tag} -> tag end)

    if length(tables_asc) != length(pattern) do
      :mismatch
    else
      new_tables =
        tables_asc
        |> Enum.zip(pattern)
        |> Enum.filter(fn {_table, tag} -> tag == :new end)
        |> Enum.map(fn {table, _tag} -> table end)

      {:ok, new_tables}
    end
  end

  @doc """
  Builds the list of `batchUpdate` request maps to substitute image tags.

  `fills` is a map keyed by variable name; each value carries `kind`,
  `default_width_px`, `separator` (atom or nil), and `media` — a list of
  `%{uri, width_px, height_px}`.

  Empty media list = the tag is still deleted (cleared).
  """
  @spec build_image_batch_requests([map()], map()) :: [map()]
  def build_image_batch_requests(ranges, fills) do
    build_image_batch_requests(ranges, fills, @default_content_width_pt)
  end

  @spec build_image_batch_requests([map()], map(), number()) :: [map()]
  def build_image_batch_requests(ranges, fills, content_width_pt) do
    ranges
    |> Enum.sort_by(& &1.start_index, :desc)
    |> Enum.flat_map(fn %{name: name, start_index: s, end_index: e} ->
      fill = Map.fetch!(fills, name)
      delete = %{deleteContentRange: %{range: %{startIndex: s, endIndex: e}}}

      inserts =
        case fill.kind do
          :image -> single_image_inserts(fill, s)
          :image_list -> list_image_inserts(fill, s, content_width_pt)
        end

      [delete | inserts]
    end)
  end

  @doc """
  Builds a single image insert request map.

  Options:
    - `:insertion_index` — document character index for insertion (required)
    - `:config` — map with `:default_width_px`, `:opacity`, `:z_index` (required)

  When `z_index > 0`, emits a `createPositionedObject` with `layout = "WRAP_TEXT"`.
  When `z_index <= 0`, emits `insertInlineImage` (default inline behaviour).
  Opacity application requires a follow-up `UpdateEmbeddedObjectPropertiesRequest`
  with the object ID returned by the batchUpdate response — not emitted here.
  A Logger warning is written when `opacity != 1.0`. This is a documented
  no-op (open risk) per the spec's "Open Risks" section: applying transparency
  requires a second batchUpdate pass after the initial insert, using the
  embedded object ID from the first response. Not yet implemented.
  """
  @spec build_single_image_request(String.t(), keyword()) :: map()
  def build_single_image_request(uri, opts) do
    index = Keyword.fetch!(opts, :insertion_index)
    config = Keyword.fetch!(opts, :config)
    w = Map.get(config, :default_width_px) || 400
    media = %{uri: uri, width_px: nil, height_px: nil}
    image_request(media, w, index, config, uri)
  end

  defp single_image_inserts(%{media: []}, _index), do: []

  defp single_image_inserts(fill, index) do
    %{media: [media | _], default_width_px: w} = fill
    [image_request(media, w, index, fill, media[:uri])]
  end

  defp list_image_inserts(%{media: []}, _index, _content_width_pt), do: []

  # Column-aware path: dispatch on columns count.
  # columns >= 2 → insertTable only. The outer build_image_batch_requests/3
  #   already emits the deleteContentRange for the placeholder; emitting
  #   another one here would produce a zero-width (invalid) delete that the
  #   Google Docs API rejects with INVALID_ARGUMENT.
  # columns == 1 → inline inserts using content-width-based PT width.
  defp list_image_inserts(fill, index, content_width_pt) do
    cols = Map.get(fill, :columns, 1)

    if cols >= 2 do
      rows = (length(fill.media) / cols) |> Float.ceil() |> trunc() |> max(1)

      [
        %{
          "insertTable" => %{
            "rows" => rows,
            "columns" => cols,
            "location" => %{"index" => index}
          }
        }
      ]
    else
      w_pt = image_width_for_columns(content_width_pt, 1)
      inline_image_inserts_pt(fill, index, w_pt)
    end
  end

  # Inline inserts using PT width directly (for image_list columns=1 path)
  defp inline_image_inserts_pt(fill, index, w_pt) do
    %{media: media, separator: sep} = fill
    reversed = Enum.reverse(media)
    last_idx = length(reversed) - 1

    reversed
    |> Enum.with_index()
    |> Enum.flat_map(fn {m, i} ->
      img = insert_inline_image_request_pt(m, w_pt, index)
      if i < last_idx, do: [img, separator_request(sep, index)], else: [img]
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Build the single batchUpdate request for an image. The Google Docs API
  # exposes only `insertInlineImage` for programmatic image insertion —
  # `createPositionedObject` is not a valid `batchUpdate` request type
  # (positioned objects can only be created interactively in the editor).
  # `opacity` is also unsupported by the API on any image surface. Both
  # options are accepted in `config` for forward-compat and ignored with a
  # warning when set away from the defaults.
  defp image_request(media, width, index, config, log_ctx) do
    z = Map.get(config, :z_index) || 0
    opacity = Map.get(config, :opacity) || 1.0

    if z > 0 do
      Logger.warning(
        "image z_index #{z} is not supported by the Google Docs API " <>
          "(positioned objects can only be created in the editor UI); " <>
          "falling back to inline insert for #{inspect(log_ctx)}"
      )
    end

    if opacity != 1.0 do
      Logger.warning(
        "image opacity #{opacity} is not supported by the Google Docs API; " <>
          "skipped for #{inspect(log_ctx)}"
      )
    end

    insert_inline_image_request(media, width, index)
  end

  defp insert_inline_image_request(
         %{uri: uri, width_px: w_px, height_px: h_px},
         default_width_px,
         index
       ) do
    scaled_height_px = scale_height(default_width_px, w_px, h_px)

    %{
      insertInlineImage: %{
        location: %{index: index},
        uri: uri,
        objectSize: %{
          width: %{magnitude: (default_width_px || 400) * @px_to_pt, unit: "PT"},
          height: %{
            magnitude: (scaled_height_px || default_width_px || 400) * @px_to_pt,
            unit: "PT"
          }
        }
      }
    }
  end

  # Like insert_inline_image_request/3 but takes width in PT directly (no px→pt conversion).
  # Used for image_list slots where width comes from image_width_for_columns/2.
  defp insert_inline_image_request_pt(media, width_pt, index) when is_map(media) do
    uri = Map.get(media, :uri) || Map.get(media, "uri")
    w_px = Map.get(media, :width_px) || Map.get(media, "width_px")
    h_px = Map.get(media, :height_px) || Map.get(media, "height_px")

    # scale_height mixes units here: target is PT, src dims are PX; the ratio cancels
    scaled_height_pt = scale_height(width_pt, w_px, h_px) || width_pt

    %{
      insertInlineImage: %{
        location: %{index: index},
        uri: uri,
        objectSize: %{
          width: %{magnitude: width_pt * 1.0, unit: "PT"},
          height: %{magnitude: scaled_height_pt * 1.0, unit: "PT"}
        }
      }
    }
  end

  # No usable source width — can't compute an aspect ratio, so fall back to the
  # native height if we have one, otherwise the target width (square-ish).
  defp scale_height(target_width, src_width, src_height) when src_width in [nil, 0],
    do: src_height || target_width

  # Source width present but height missing. The Google API can return media
  # with a width and no height; without this guard the arithmetic clause below
  # evaluates round(target * nil / width) and raises an ArithmeticError — the
  # same crash class PR #27 fixed at the data source. Fall back to target_width.
  defp scale_height(target_width, _src_width, nil), do: target_width

  defp scale_height(target_width, src_width, src_height) do
    round(target_width * src_height / src_width)
  end

  defp separator_request(:none, _index), do: nil

  defp separator_request(sep, index) do
    text =
      case sep do
        :newline -> "\n"
        :space -> " "
      end

    %{insertText: %{text: text, location: %{index: index}}}
  end

  @doc """
  Two-step image substitution: GET the document, build the batch, send it.

  `fills` is the same shape as `build_image_batch_requests/2`.

  Options (used in tests):
    * `:get_fn` — overrides `get_document/1`
    * `:batch_fn` — overrides `batch_update/2`
  """
  @spec substitute_images(String.t(), map(), keyword()) ::
          {:ok, map() | :noop} | {:error, term()}
  def substitute_images(doc_id, fills, opts \\ []) when is_map(fills) do
    if map_size(fills) == 0 do
      {:ok, :noop}
    else
      get_fn = Keyword.get(opts, :get_fn, &get_document/1)
      batch_fn = Keyword.get(opts, :batch_fn, &batch_update/2)

      with {:ok, %{body: doc}} <- get_fn.(doc_id),
           ranges = find_image_tag_ranges(doc, Map.keys(fills)),
           requests = build_image_batch_requests(ranges, fills),
           {:ok, _} = result <- maybe_batch(batch_fn, doc_id, requests) do
        result
      else
        {:error, _} = err -> err
      end
    end
  end

  defp maybe_batch(_fn, _id, []), do: {:ok, %{}}
  defp maybe_batch(fn_, id, requests), do: fn_.(id, requests)

  # ===========================================================================
  # Google Drive API
  # ===========================================================================

  @doc """
  Upload a raw image binary to Drive and return a public, embeddable URL.

  Used when inserting an image into a Google Doc via `insertInlineImage`,
  which requires a fetchable URL (not raw bytes). Uploads the binary to
  Drive, grants anyone-with-link read access, and returns an
  `lh3.googleusercontent.com/d/<id>` URL that Google's image fetcher can
  read without following a redirect.

    - `data` — raw image bytes
    - `mime_type` — MIME type string, e.g. `"image/jpeg"`
    - `opts` — optional keyword list; supports `:name` (file name, defaults to
      `"embed-image"`)
  """
  @spec upload_image_for_embedding(binary(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def upload_image_for_embedding(data, mime_type, opts \\ [])
      when is_binary(data) and is_binary(mime_type) do
    name = Keyword.get(opts, :name, "embed-image")

    # Step 1: upload the binary via the Drive simple-upload endpoint.
    # The metadata and the file body are sent in a multipart/related request.
    boundary = "---pkdc_boundary_#{:erlang.unique_integer([:positive])}"
    # Minimal JSON string escaping (backslash first, then quote) so a name
    # containing either char can't break out of the metadata object. Avoids a
    # transitive Jason dependency for this single fixed-key payload.
    escaped_name = name |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    meta_json = "{\"name\":\"#{escaped_name}\"}"

    body =
      "--#{boundary}\r\n" <>
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" <>
        meta_json <>
        "\r\n--#{boundary}\r\n" <>
        "Content-Type: #{mime_type}\r\n\r\n" <>
        data <>
        "\r\n--#{boundary}--"

    upload_opts = [
      headers: [{"content-type", "multipart/related; boundary=#{boundary}"}],
      body: body,
      params: [uploadType: "multipart", fields: "id"]
    ]

    case authenticated_request(:post, "#{@drive_upload_base}/files", upload_opts) do
      {:ok, %{status: status, body: %{"id" => file_id}}} when status in 200..299 ->
        case set_anyone_reader_permission(file_id) do
          :ok ->
            # lh3.googleusercontent.com/d/<file_id> serves the raw image binary
            # (HTTP 200, no redirect). drive.google.com/uc?export=view returns a
            # 303 the Docs insertInlineImage fetcher does not follow → 400
            # INVALID_ARGUMENT.
            {:ok, "https://lh3.googleusercontent.com/d/#{file_id}"}

          {:error, _} = err ->
            err
        end

      {:ok, %{body: body}} ->
        log_drive_error("upload image for embedding failed", body)
        {:error, :upload_failed}

      {:error, _} = err ->
        err
    end
  end

  # Grant anyone-with-link read access to a Drive file so Google's servers
  # can fetch it when embedding via insertInlineImage.
  defp set_anyone_reader_permission(file_id) do
    body = %{type: "anyone", role: "reader"}

    case authenticated_request(
           :post,
           "#{@drive_base}/files/#{file_id}/permissions",
           json: body
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{body: body}} ->
        log_drive_error("set anyone reader permission failed", body)
        {:error, :permission_failed}

      {:error, _} = err ->
        err
    end
  end

  @doc "Move a file to a different folder in Google Drive."
  @spec move_file(String.t(), String.t()) ::
          :ok
          | {:error,
             :invalid_file_id
             | :move_failed
             | :get_file_parents_failed
             | :drive_file_not_found
             | term()}
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
          {:ok, %{status: status}} when status in 200..299 ->
            :ok

          {:ok, %{status: 404}} ->
            {:error, :drive_file_not_found}

          {:ok, %{body: body}} ->
            log_drive_error("move failed", body)
            {:error, :move_failed}

          {:error, _} = err ->
            err
        end

      {:ok, %{status: 404}} ->
        {:error, :drive_file_not_found}

      {:ok, %{body: body}} ->
        log_drive_error("get file parents failed", body)
        {:error, :get_file_parents_failed}

      {:error, _} = err ->
        err
    end
  end

  @doc "Rename a file in Google Drive."
  @spec rename_file(String.t(), String.t()) ::
          :ok | {:error, :invalid_file_id | :rename_failed | term()}
  def rename_file(file_id, new_name) do
    with {:ok, fid} <- validate_file_id(file_id) do
      case authenticated_request(:patch, "#{@drive_base}/files/#{fid}", json: %{name: new_name}) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{body: body}} ->
          log_drive_error("rename failed", body)
          {:error, :rename_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Copy a file in Google Drive. Returns the new file's ID."
  @spec copy_file(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_file_id | :copy_failed | term()}
  def copy_file(file_id, new_name, opts \\ []) do
    with {:ok, fid} <- validate_file_id(file_id) do
      parent = Keyword.get(opts, :parent)
      body = %{name: new_name}
      body = if parent, do: Map.put(body, :parents, [parent]), else: body

      case authenticated_request(:post, "#{@drive_base}/files/#{fid}/copy", json: body) do
        {:ok, %{status: status, body: %{"id" => new_id}}} when status in 200..299 ->
          {:ok, new_id}

        {:ok, %{body: body}} ->
          log_drive_error("copy failed", body)
          {:error, :copy_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Export a Google Doc as PDF. Returns `{:ok, pdf_binary}`."
  @spec export_pdf(String.t()) ::
          {:ok, binary()} | {:error, :invalid_file_id | :pdf_export_failed | term()}
  def export_pdf(doc_id) do
    with {:ok, fid} <- validate_file_id(doc_id) do
      case authenticated_request(:get, "#{@drive_base}/files/#{fid}/export",
             params: [mimeType: "application/pdf"]
           ) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          {:ok, body}

        {:ok, %{body: body}} ->
          log_drive_error("PDF export failed", body)
          {:error, :pdf_export_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Fetch a document thumbnail as a base64 data URI via the Drive API."
  @spec fetch_thumbnail(term()) ::
          {:ok, String.t()}
          | {:error,
             :no_doc_id
             | :no_thumbnail
             | :thumbnail_link_failed
             | :thumbnail_fetch_failed
             | :invalid_file_id
             | term()}
  def fetch_thumbnail(doc_id) when is_binary(doc_id) and doc_id != "" do
    with {:ok, fid} <- validate_file_id(doc_id) do
      case authenticated_request(:get, "#{@drive_base}/files/#{fid}",
             params: [fields: "thumbnailLink"]
           ) do
        {:ok, %{status: 200, body: %{"thumbnailLink" => link}}} when is_binary(link) ->
          fetch_thumbnail_image(link)

        {:ok, %{status: 200}} ->
          {:error, :no_thumbnail}

        {:ok, %{body: body}} ->
          log_drive_error("get thumbnail link failed", body)
          {:error, :thumbnail_link_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  def fetch_thumbnail(_), do: {:error, :no_doc_id}

  # SSRF guard. The `thumbnailLink` URL comes from the Drive API response,
  # but a compromised network path or a misconfigured proxy could
  # substitute it with a URL pointing at internal infrastructure
  # (cloud-metadata endpoints at 169.254.169.254, internal admin panels
  # at 10/172/192.x, localhost). Reject anything that isn't on Google's
  # public thumbnail CDN before we pass the URL to `Req.get/1`.
  @thumbnail_host_suffixes [".googleusercontent.com", ".google.com"]

  @doc false
  # Public-but-not-API: exposed so tests can pin the SSRF guard
  # (allowlist + redirect block) without driving a full Drive auth
  # flow. Same shape as `validate_thumbnail_url/1` above.
  @spec fetch_thumbnail_image(String.t()) ::
          {:ok, String.t()} | {:error, :thumbnail_fetch_failed}
  def fetch_thumbnail_image(url) when is_binary(url) do
    case validate_thumbnail_url(url) do
      :ok ->
        do_fetch_thumbnail_image(url)

      {:error, reason} ->
        Logger.warning(
          "[DocumentCreator] thumbnail URL rejected | reason=#{reason} | url=#{inspect(url)}"
        )

        {:error, :thumbnail_fetch_failed}
    end
  end

  @doc false
  # Public-but-not-API: exposed so tests can pin the SSRF guard
  # without driving a full HTTP fetch. The accepted suffixes are an
  # allowlist of Google's public thumbnail CDNs.
  @spec validate_thumbnail_url(String.t()) :: :ok | {:error, :invalid_url | :host_not_allowed}
  def validate_thumbnail_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if Enum.any?(@thumbnail_host_suffixes, &String.ends_with?(host, &1)),
          do: :ok,
          else: {:error, :host_not_allowed}

      _ ->
        {:error, :invalid_url}
    end
  end

  def validate_thumbnail_url(_), do: {:error, :invalid_url}

  defp do_fetch_thumbnail_image(url) do
    # `:req_options` is empty in production. Tests opt in via
    # `Application.put_env(:phoenix_kit_document_creator, :req_options,
    # plug: {Req.Test, Stub})` to route through `Req.Test` stubs without
    # external HTTP traffic — same pattern as the AI module's coverage
    # push (e4519a8 + 5bbf273).
    #
    # `redirect: false` is prepended so it wins via Keyword.get/2's
    # first-match semantics — `:req_options` cannot disable it. Req
    # follows redirects by default (~> 0.5), and
    # `validate_thumbnail_url/1` only checks the input URL. Without
    # this, a 302 from a Google CDN host to 169.254.169.254 would be
    # followed silently and bypass the SSRF allowlist. The thumbnail
    # endpoint never legitimately redirects, so closing it off is safe.
    opts =
      [redirect: false] ++ Application.get_env(:phoenix_kit_document_creator, :req_options, [])

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type = extract_content_type(headers)

        {:ok, "data:#{content_type};base64,#{Base.encode64(body)}"}

      {:ok, %{status: status}} ->
        Logger.warning("[DocumentCreator] thumbnail fetch returned non-200 | status=#{status}")
        {:error, :thumbnail_fetch_failed}

      {:error, exception} ->
        Logger.warning(
          "[DocumentCreator] thumbnail fetch failed | message=#{Exception.message(exception)}"
        )

        {:error, :thumbnail_fetch_failed}
    end
  end

  # ===========================================================================
  # Composition helpers (used by Documents.Composer)
  # ===========================================================================

  @doc """
  Copy a Google Doc for use as the base of a composed document.

  Returns `{:ok, new_doc_id}`. The copy is named by its source doc ID so it
  can be identified for best-effort cleanup on rollback before a final name
  is applied.
  """
  @spec copy_document(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def copy_document(source_doc_id, opts \\ []) do
    copy_opts =
      case Keyword.get(opts, :destination_folder_id) do
        nil -> []
        folder_id -> [parent: folder_id]
      end

    copy_file(source_doc_id, "composed-doc-#{source_doc_id}", copy_opts)
  end

  @doc """
  Append a template's content to an existing Google Doc via batchUpdate.

  Inserts a page break followed by the content of `template_doc_id` into
  `target_doc_id`. Returns `{:ok, {start_index, end_index}}` representing the
  character range of the inserted content — callers use this for
  section-scoped substitution.

  Paragraph text is inserted via a single `insertText`, same as before this
  function also handled tables. Tables are NOT part of that flattened text —
  there is no Docs API primitive for "paste another document's table here" —
  so they are rebuilt in two extra batchUpdate passes, reusing the exact
  pattern already proven for image-grid tables (`table_image_inserts/3` ->
  re-fetch -> `match_new_tables/3` -> `fill_table_cells/3`):

    1. `flatten_template_with_table_markers/1` walks the template like
       `get_document_text/1` does, but emits a unique marker token at each
       table's position (instead of silently dropping it) and captures the
       table's `{rows, columns, cell text}` separately, in document order.
       The marked-up text is inserted via the same single `insertText` as
       before.
    2. Re-fetch, locate the markers (`find_table_marker_ranges/1`), and
       replace each with a bare table of the right size
       (`table_skeleton_requests/2`) in one batchUpdate.
    3. Re-fetch again, identify the newly-inserted tables (`match_new_tables/3`,
       reused as-is), and fill every cell with its captured text
       (`fill_table_cells_text/2`) in one batchUpdate. Any `{{var}}`
       placeholder that lived inside a table cell is now physically present
       in the document, so it substitutes normally in
       `Composer.apply_substitutions/4` like any other text.

  Templates with no tables skip steps 2-3 entirely — this reduces to exactly
  the previous single-`insertText` behaviour, with no extra Docs API calls.

  Formatting fidelity: table column widths
  (`tableStyle.tableColumnProperties`, fixed-width columns only — evenly
  distributed is `insertTable`'s own default) are captured during flatten
  and replayed via `updateTableColumnProperties` in the Phase 2 (cell-fill)
  batch, targeting the table's real post-insert `startIndex` from the
  re-fetch already done for cell matching — NOT the Phase 1b skeleton
  batch, since `insertTable`'s own `location` index cannot be trusted as
  the resulting table's position (verified live: Google inserts an
  implicit paragraph break ahead of a table landing mid-paragraph, shifting
  its real `startIndex` by one from the requested location — see
  `table_column_width_requests/2`'s doc). Per-run character style — bold,
  italic, font size, foreground color — is captured for both table cell
  text and the section's own (non-table) body text, and replayed via
  `updateTextStyle` immediately after the corresponding `insertText`. Every
  inserted character is covered by an explicit range, including `bold:
  false`/`italic: false` for plain runs, so freshly inserted text can never
  silently inherit formatting from neighboring content already in the
  target document.

  Known limitations: cell shading, borders, and merged cells are not
  restored — `insertTable` creates a bare table beyond the column widths
  above. Paragraph-level formatting (alignment, named heading styles, list
  bullets) is not replayed, only character-level text style. Nested tables
  (a table inside a table cell) are not supported.

  Options (used in tests):
    * `:get_fn` — overrides `get_document/1` (used for both the template
      fetch and every target-document re-fetch)
    * `:batch_fn` — overrides `batch_update/2`
  """
  @spec append_template(String.t(), String.t(), keyword()) ::
          {:ok, {integer(), integer()}} | {:error, term()}
  def append_template(target_doc_id, template_doc_id, opts \\ []) do
    get_fn = Keyword.get(opts, :get_fn, &get_document/1)
    batch_fn = Keyword.get(opts, :batch_fn, &batch_update/2)

    with {:ok, %{body: template_doc}} <- get_fn.(template_doc_id),
         {text, tables, body_runs} = flatten_template_with_table_markers_and_styles(template_doc),
         {:ok, %{body: current_doc}} <- get_fn.(target_doc_id) do
      end_index = document_end_index(current_doc)
      insert_index = max(end_index - 1, 1)
      content_start = insert_index + 1

      requests =
        [
          %{insertPageBreak: %{location: %{index: insert_index}}},
          %{insertText: %{location: %{index: content_start}, text: text}}
        ] ++ text_style_requests(content_start, body_runs)

      case batch_fn.(target_doc_id, requests) do
        {:ok, _} ->
          finish_append_template(target_doc_id, content_start, text, tables, get_fn, batch_fn)

        {:error, _} = err ->
          err
      end
    end
  end

  # No tables in this template — previous behaviour, no extra Docs API calls.
  # UTF-16 unit count is used because Google Docs indices count UTF-16 code
  # units, not graphemes: for BMP-only text these are equal, but emoji and
  # rare CJK codepoints occupy two UTF-16 units (a surrogate pair).
  defp finish_append_template(_target_doc_id, content_start, text, [], _get_fn, _batch_fn) do
    {:ok, {content_start, content_start + utf16_units(text)}}
  end

  # Tables present: rebuild them via the marker -> skeleton -> fill pipeline
  # described in append_template/3's doc. A final re-fetch computes the true
  # content_end from the actual document state (rather than the marked-up
  # text's length), since inserting real tables changes the document's
  # length beyond what the marker text occupied — and Google may add its own
  # structural padding around an inserted table that isn't worth predicting
  # analytically when a re-fetch gives the exact answer.
  defp finish_append_template(target_doc_id, content_start, _text, tables, get_fn, batch_fn) do
    tables_by_index = Map.new(tables, &{&1.marker_index, &1})

    with {:ok, %{body: doc1}} <- get_fn.(target_doc_id),
         marker_ranges = find_table_marker_ranges(doc1),
         :ok <- verify_marker_count(marker_ranges, tables),
         pre_existing_starts = doc1 |> collect_tables() |> Enum.map(& &1["startIndex"]),
         skeleton_requests = table_skeleton_requests(marker_ranges, tables_by_index),
         {:ok, _} <- maybe_batch(batch_fn, target_doc_id, skeleton_requests),
         {:ok, %{body: doc2}} <- get_fn.(target_doc_id),
         slot_starts = marker_ranges |> Enum.map(& &1.start_index) |> Enum.sort(),
         tables_asc = doc2 |> collect_tables() |> Enum.sort_by(& &1["startIndex"]),
         {:ok, new_tables} <- match_new_tables(tables_asc, pre_existing_starts, slot_starts),
         fill_requests = build_table_fill_requests(marker_ranges, new_tables, tables_by_index),
         {:ok, _} <- maybe_batch(batch_fn, target_doc_id, fill_requests),
         {:ok, %{body: final_doc}} <- get_fn.(target_doc_id) do
      {:ok, {content_start, document_end_index(final_doc) - 1}}
    else
      :mismatch ->
        Logger.error(
          "append_template: table match mismatch while appending tables into doc #{target_doc_id}"
        )

        {:error, :table_match_mismatch}

      {:error, _} = err ->
        err
    end
  end

  defp verify_marker_count(marker_ranges, tables) do
    if length(marker_ranges) == length(tables) do
      :ok
    else
      {:error, :table_marker_count_mismatch}
    end
  end

  # Sentinel wrapped in spaces (per the diagnosis's own recommendation) so it
  # reads as ordinary, API-safe plain text — no reliance on control
  # characters or private-use codepoints surviving an insertText round-trip.
  # The surrounding spaces are part of the match (and the delete), so no
  # stray whitespace is left behind once the marker is replaced.
  @table_marker_regex ~r/ __PKDC_TABLE_(\d+)__ /

  defp table_marker(n), do: " __PKDC_TABLE_#{n}__ "

  @doc """
  Phase 0 of the append-with-tables pipeline (see `append_template/3`).

  Flattens a template document's body the same way `get_document_text/1`
  does for paragraphs, but instead of silently skipping table blocks, emits a
  unique marker token at each table's position and captures its structure
  separately.

  This is a distinct code path from `get_document_text/1` — that function's
  existing behaviour (silently skipping tables) is relied on by its other
  callers (`Documents.detect_variables/1`,
  `Documents.image_slots_for_template/1`) and is intentionally left
  untouched.

  Returns `{text, tables}`. `tables` is a list of
  `%{marker_index: pos_integer(), rows: pos_integer(), columns: pos_integer(),
  cell_texts: [String.t()]}`, one entry per table, in document order.
  `cell_texts` is row-major (row 0's cells left-to-right, then row 1's, ...),
  one entry per table cell — the same order `extract_table_cells/1` (private)
  and `fill_table_cells_text/2` enumerate cells in.

  Nested tables (a table inside a table cell) are not supported: a cell's
  text is captured from its paragraph blocks only, same limitation the
  top-level flatten has.

  This is a thin wrapper around `flatten_template_with_table_markers_and_styles/1`
  that drops its third return value (`body_runs`) — kept at its original
  2-tuple arity so existing callers are unaffected by the style-capture
  addition.
  """
  @spec flatten_template_with_table_markers(map()) :: {String.t(), [map()]}
  def flatten_template_with_table_markers(doc) do
    {text, tables, _body_runs} = flatten_template_with_table_markers_and_styles(doc)
    {text, tables}
  end

  @doc """
  Same walk as `flatten_template_with_table_markers/1`, additionally
  capturing per-run character style (bold, italic, font size, foreground
  color) — see `append_template/3`'s "Formatting fidelity" doc section.

  Returns `{text, tables, body_runs}`:

    * `text`, `tables` — identical to `flatten_template_with_table_markers/1`,
      except each table map in `tables` gains two keys: `column_properties`
      (the source table's `tableStyle.tableColumnProperties`, normalized to
      `%{width_type, magnitude, unit}`, one per column, `[]` if the source
      table has none) and `cell_runs` (one run-list per cell, parallel to
      `cell_texts`, same order — see `text_style_requests/2`'s run shape).
    * `body_runs` — the non-table body text's per-run style spans, same run
      shape as a `cell_runs` entry, with `start_offset`/`length` in UTF-16
      units relative to the start of `text` (table markers consume offset
      but contribute no run — they're deleted before any style request
      referencing them would apply).
  """
  @spec flatten_template_with_table_markers_and_styles(map()) :: {String.t(), [map()], [map()]}
  def flatten_template_with_table_markers_and_styles(doc) do
    blocks = get_in(doc, ["body", "content"]) |> List.wrap()

    {rev_chunks, rev_tables, rev_body_runs, _next_marker, _offset} =
      Enum.reduce(blocks, {[], [], [], 1, 0}, &flatten_block_with_styles/2)

    text = rev_chunks |> Enum.reverse() |> Enum.join()
    {text, Enum.reverse(rev_tables), Enum.reverse(rev_body_runs)}
  end

  defp flatten_block_with_styles(
         %{"paragraph" => %{"elements" => elements}},
         {chunks, tables, body_runs, n, offset}
       ) do
    runs = text_runs_with_styles(elements, offset)
    para_text = Enum.map_join(runs, & &1.text)
    new_offset = offset + utf16_units(para_text)
    {[para_text | chunks], tables, Enum.reverse(runs) ++ body_runs, n, new_offset}
  end

  defp flatten_block_with_styles(%{"table" => table}, {chunks, tables, body_runs, n, offset}) do
    {rows, columns} = table_dimensions(table)
    table_rows = Map.get(table, "tableRows", [])
    cell_texts = Enum.flat_map(table_rows, &row_cell_texts/1)
    cell_runs = Enum.flat_map(table_rows, &row_cell_runs/1)
    column_properties = extract_column_properties(table)

    table_info = %{
      marker_index: n,
      rows: rows,
      columns: columns,
      cell_texts: cell_texts,
      cell_runs: cell_runs,
      column_properties: column_properties
    }

    marker = table_marker(n)
    new_offset = offset + utf16_units(marker)

    {[marker | chunks], [table_info | tables], body_runs, n + 1, new_offset}
  end

  defp flatten_block_with_styles(_block, acc), do: acc

  # Walks a paragraph's `elements` list (or a table cell's, flattened across
  # its own paragraph blocks — see `cell_style_runs/1`) and returns one run
  # per non-empty textRun: `%{text, start_offset, length, bold, italic,
  # font_size, color}`. `start_offset`/`length` are UTF-16 units, threaded
  # from `start_offset` so callers can place runs at an absolute document
  # index later (`text_style_requests/2`). Elements without a `"textRun"`
  # key (or with empty content) contribute no run and no offset advance —
  # same no-op `get_in(...) || ""` fallback `flatten_block_with_styles/2`
  # relied on before style capture was added.
  defp text_runs_with_styles(elements, start_offset) do
    {rev_runs, _final_offset} =
      Enum.reduce(elements, {[], start_offset}, fn el, {acc, offset} ->
        content = get_in(el, ["textRun", "content"]) || ""

        if content == "" do
          {acc, offset}
        else
          style = get_in(el, ["textRun", "textStyle"]) || %{}
          len = utf16_units(content)

          run = %{
            text: content,
            start_offset: offset,
            length: len,
            bold: Map.get(style, "bold", false),
            italic: Map.get(style, "italic", false),
            font_size: get_in(style, ["fontSize", "magnitude"]),
            color: get_in(style, ["foregroundColor", "color", "rgbColor"])
          }

          {[run | acc], offset + len}
        end
      end)

    Enum.reverse(rev_runs)
  end

  # Column widths the source table explicitly set. Only `FIXED_WIDTH`
  # columns carry a `width` worth replaying — `EVENLY_DISTRIBUTED` (or a
  # column with no captured property at all) is already `insertTable`'s own
  # default, so `table_column_width_requests/2` skips it rather than
  # emitting a no-op request.
  defp extract_column_properties(%{"tableStyle" => %{"tableColumnProperties" => props}})
       when is_list(props) do
    Enum.map(props, &normalize_column_property/1)
  end

  defp extract_column_properties(_), do: []

  defp normalize_column_property(%{
         "widthType" => "FIXED_WIDTH",
         "width" => %{"magnitude" => mag} = width
       })
       when is_number(mag) do
    %{width_type: "FIXED_WIDTH", magnitude: mag * 1.0, unit: Map.get(width, "unit", "PT")}
  end

  defp normalize_column_property(%{"widthType" => width_type}) do
    %{width_type: width_type, magnitude: nil, unit: nil}
  end

  defp normalize_column_property(_), do: %{width_type: nil, magnitude: nil, unit: nil}

  defp table_dimensions(%{"rows" => r, "columns" => c}) when is_integer(r) and is_integer(c) do
    {max(r, 1), max(c, 1)}
  end

  defp table_dimensions(%{"tableRows" => rows}) do
    columns = rows |> Enum.map(&row_length/1) |> Enum.max(fn -> 1 end)
    {max(length(rows), 1), max(columns, 1)}
  end

  defp table_dimensions(_), do: {1, 1}

  defp row_length(%{"tableCells" => cells}), do: length(cells)
  defp row_length(_), do: 0

  defp row_cell_texts(%{"tableCells" => cells}), do: Enum.map(cells, &cell_text/1)
  defp row_cell_texts(_), do: []

  # Same join `get_document_text/1` uses, scoped to one cell's content, minus
  # the trailing newline contributed by the cell's last paragraph (that
  # newline is already present in the target table's default empty
  # paragraph, so keeping ours too would leave a spurious blank trailing
  # line in every filled cell).
  defp cell_text(%{"content" => content}) do
    content
    |> Enum.flat_map(fn el -> get_in(el, ["paragraph", "elements"]) || [] end)
    |> Enum.map_join(fn el -> get_in(el, ["textRun", "content"]) || "" end)
    |> strip_trailing_newline()
  end

  defp cell_text(_), do: ""

  defp strip_trailing_newline(text) do
    if String.ends_with?(text, "\n") do
      binary_part(text, 0, byte_size(text) - 1)
    else
      text
    end
  end

  defp row_cell_runs(%{"tableCells" => cells}), do: Enum.map(cells, &cell_style_runs/1)
  defp row_cell_runs(_), do: []

  # Per-run style variant of `cell_text/1` — same traversal (flatten across
  # the cell's paragraph blocks, offsets local to the cell starting at 0
  # since each cell gets its own `insertText`), trimming the same trailing
  # newline `cell_text/1` trims, off the last run instead of the joined
  # string. `Enum.map_join(cell_style_runs(cell), & &1.text)` always equals
  # `cell_text(cell)` — same source data, decomposed differently.
  defp cell_style_runs(%{"content" => content}) do
    content
    |> Enum.flat_map(fn el -> get_in(el, ["paragraph", "elements"]) || [] end)
    |> text_runs_with_styles(0)
    |> strip_trailing_newline_from_runs()
    |> Enum.reject(&(&1.text == ""))
  end

  defp cell_style_runs(_), do: []

  defp strip_trailing_newline_from_runs([]), do: []

  defp strip_trailing_newline_from_runs(runs) do
    {init, [last]} = Enum.split(runs, -1)

    if String.ends_with?(last.text, "\n") do
      init ++
        [
          %{
            last
            | text: binary_part(last.text, 0, byte_size(last.text) - 1),
              length: last.length - 1
          }
        ]
    else
      runs
    end
  end

  @doc """
  Phase 1a of the append-with-tables pipeline (see `append_template/3`):
  locate `flatten_template_with_table_markers/1` marker tokens in an
  already-fetched document. Mirrors `find_text_var_ranges/2`'s UTF-16 index
  arithmetic (`Regex.scan(..., return: :index)` yields byte offsets; Google
  Docs indices count UTF-16 code units).
  """
  @spec find_table_marker_ranges(map()) :: [
          %{marker_index: integer(), start_index: integer(), end_index: integer()}
        ]
  def find_table_marker_ranges(doc) do
    doc
    |> body_text_runs()
    |> Enum.flat_map(&extract_marker_ranges/1)
  end

  defp extract_marker_ranges(%{"textRun" => %{"content" => content}, "startIndex" => base}) do
    Regex.scan(@table_marker_regex, content, return: :index)
    |> Enum.map(fn [{full_byte_start, full_byte_len}, {idx_byte_start, idx_byte_len}] ->
      u16_start = content |> binary_part(0, full_byte_start) |> utf16_units()
      u16_len = content |> binary_part(full_byte_start, full_byte_len) |> utf16_units()
      marker_index = content |> binary_part(idx_byte_start, idx_byte_len) |> String.to_integer()

      %{
        marker_index: marker_index,
        start_index: base + u16_start,
        end_index: base + u16_start + u16_len
      }
    end)
  end

  defp extract_marker_ranges(_), do: []

  @doc """
  Phase 1b of the append-with-tables pipeline (see `append_template/3`): for
  each located marker, delete the marker text and insert a bare table of its
  captured dimensions at that position. Sorted descending by `start_index`
  (same convention as `substitute_all_text/4` and
  `build_image_batch_requests/3`) so earlier replacements in the list don't
  shift the indices of markers still to be processed.

  Column widths are deliberately NOT applied here even though the table's
  captured `column_properties` are available at this point — see
  `table_column_width_requests/2`'s doc for why `insertTable`'s `location`
  index cannot be trusted as the resulting table's real `tableStartLocation`.
  """
  @spec table_skeleton_requests([map()], %{integer() => map()}) :: [map()]
  def table_skeleton_requests(marker_ranges, tables_by_index) do
    marker_ranges
    |> Enum.sort_by(& &1.start_index, :desc)
    |> Enum.flat_map(fn %{marker_index: idx, start_index: s, end_index: e} ->
      %{rows: rows, columns: columns} = Map.fetch!(tables_by_index, idx)

      [
        %{"deleteContentRange" => %{"range" => %{"startIndex" => s, "endIndex" => e}}},
        %{"insertTable" => %{"rows" => rows, "columns" => columns, "location" => %{"index" => s}}}
      ]
    end)
  end

  @doc """
  Column-width companion used by `build_table_fill_requests/3` (Phase 2, NOT
  the Phase 1b skeleton batch — see below). `table_start_index` must be a
  table's real, post-insert `startIndex` from a re-fetched document (the
  same value `extract_table_cells/1`'s caller already has via
  `match_new_tables/3`'s matched table element), never the `location.index`
  an `insertTable` request was given. `column_properties` is a table's
  captured `column_properties` list (see
  `flatten_template_with_table_markers_and_styles/1`), index-aligned to the
  table's columns.

  Verified live against the real Docs API: `insertTable` at `location.index
  = 8` produced a table whose actual `startIndex` was `9`, one past the
  requested location — Google inserts an implicit paragraph break ahead of
  a table landing mid-paragraph, and `updateTableColumnProperties` rejects
  the un-adjusted index with `INVALID_ARGUMENT: The provided table start
  location is invalid`. This is exactly why `finish_append_template/6`
  re-fetches after the skeleton batch before filling cells — this function
  rides along on that same re-fetch instead of trying to predict the offset
  analytically.

  Only `FIXED_WIDTH` columns produce a request — `EVENLY_DISTRIBUTED` (or a
  column with no captured property) is already what a bare `insertTable`
  produces, so emitting a request for it would be a no-op round trip. One
  request per fixed column (the Docs API's `columnIndices` field lets one
  request retarget several columns sharing an identical width, but per-
  column source widths are rarely identical in practice, so this keeps the
  mapping simple and correct over minimizing request count).
  """
  @spec table_column_width_requests(integer(), [map()]) :: [map()]
  def table_column_width_requests(table_start_index, column_properties) do
    column_properties
    |> Enum.with_index()
    |> Enum.filter(fn {prop, _i} ->
      prop.width_type == "FIXED_WIDTH" and is_number(prop.magnitude)
    end)
    |> Enum.map(fn {prop, i} ->
      %{
        "updateTableColumnProperties" => %{
          "tableStartLocation" => %{"index" => table_start_index},
          "columnIndices" => [i],
          "tableColumnProperties" => %{
            "widthType" => "FIXED_WIDTH",
            "width" => %{"magnitude" => prop.magnitude, "unit" => prop.unit || "PT"}
          },
          "fields" => "width,widthType"
        }
      }
    end)
  end

  @doc """
  Phase 2 of the append-with-tables pipeline (see `append_template/3`): text
  variant of `fill_table_cells/3`. Emits `insertText` requests for each
  cell's captured text, last-first so earlier inserts don't shift later
  indices. A cell whose captured text is empty is left untouched (its
  default empty paragraph already reads as empty).
  """
  @spec fill_table_cells_text([%{insert_index: integer()}], [String.t()]) :: [map()]
  def fill_table_cells_text(cells, cell_texts) when is_list(cells) and is_list(cell_texts) do
    cells
    |> Enum.zip(cell_texts)
    |> Enum.reverse()
    |> Enum.map(fn {%{insert_index: idx}, text} -> text_insert_request(idx, text) end)
    |> Enum.reject(&is_nil/1)
  end

  defp text_insert_request(_idx, ""), do: nil

  defp text_insert_request(idx, text),
    do: %{"insertText" => %{"location" => %{"index" => idx}, "text" => text}}

  @doc """
  Builds `updateTextStyle` requests replaying captured per-run character
  style (see `flatten_template_with_table_markers_and_styles/1`'s `cell_runs`
  / `body_runs`), anchored at `base_index` — the same index the
  corresponding `insertText` used. Adjacent runs sharing identical style are
  merged into one range first, but every non-empty run is still covered,
  including a plain run's explicit `bold: false`/`italic: false` — this is
  deliberate: a freshly inserted blob of text otherwise inherits its style
  from whatever character precedes it in the target document, so leaving a
  plain run unstyled would silently pick up bold/italic from neighboring
  content (seen live: an appended section's plain paragraph inheriting bold
  from an adjacent heading).

  Safe to batch immediately after the insert it styles: text style changes
  never shift document character indices, so nothing else in the same batch
  needs to account for these requests' presence.
  """
  @spec text_style_requests(integer(), [map()]) :: [map()]
  def text_style_requests(base_index, runs) when is_list(runs) do
    runs
    |> merge_style_runs()
    |> Enum.filter(&(&1.length > 0))
    |> Enum.map(fn run ->
      text_style_request(
        base_index + run.start_offset,
        base_index + run.start_offset + run.length,
        run
      )
    end)
  end

  defp merge_style_runs([]), do: []

  defp merge_style_runs([first | rest]) do
    rest
    |> Enum.reduce([first], fn run, [prev | acc] ->
      if contiguous_same_style?(prev, run) do
        [%{prev | length: prev.length + run.length} | acc]
      else
        [run, prev | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp contiguous_same_style?(prev, run) do
    prev.start_offset + prev.length == run.start_offset and
      prev.bold == run.bold and prev.italic == run.italic and
      prev.font_size == run.font_size and prev.color == run.color
  end

  defp text_style_request(range_start, range_end, style) do
    {text_style, fields} = text_style_fields(style)

    %{
      "updateTextStyle" => %{
        "range" => %{"startIndex" => range_start, "endIndex" => range_end},
        "textStyle" => text_style,
        "fields" => fields
      }
    }
  end

  # Bold/italic are always set explicitly (see text_style_requests/2's doc —
  # this is the anti-inheritance guarantee). Font size and foreground color
  # are only included, in both the textStyle object and the fields mask,
  # when the source run actually carried one.
  defp text_style_fields(%{bold: bold, italic: italic, font_size: font_size, color: color}) do
    style = %{"bold" => bold, "italic" => italic}
    fields = ["bold", "italic"]

    {style, fields} =
      if is_number(font_size) do
        {Map.put(style, "fontSize", %{"magnitude" => font_size * 1.0, "unit" => "PT"}),
         fields ++ ["fontSize"]}
      else
        {style, fields}
      end

    case color do
      rgb_color when is_map(rgb_color) ->
        # `is_map/1`, not "non-empty map": Google omits zero-valued RGB
        # channels, so pure black is a legitimate `%{}` — that still means
        # "this run has an explicit foreground color (black)", distinct from
        # `nil` ("no foregroundColor captured at all").
        {Map.put(style, "foregroundColor", %{"color" => %{"rgbColor" => rgb_color}}),
         Enum.join(fields ++ ["foregroundColor"], ",")}

      _ ->
        {style, Enum.join(fields, ",")}
    end
  end

  # Column widths are applied here (Phase 2), not alongside the Phase 1b
  # skeleton — see `table_column_width_requests/2`'s doc: `table_el` here
  # comes from a document re-fetched AFTER the skeleton batch, so
  # `table_el["startIndex"]` is the table's real position, unlike the
  # marker's `start_index` a skeleton-phase request would have had to guess
  # at. Column-width requests don't shift character indices, so they're
  # safe to run in any order relative to the cell-fill requests below —
  # placed first here only for readability (structure before content).
  #
  # Merges every matched table's cell fills into one globally-ordered request
  # list. Fills must be applied in descending index order ACROSS tables (not
  # just within one), since an earlier insert would otherwise shift a later
  # table's captured cell indices. Each cell's `insertText` is immediately
  # followed by its `text_style_requests/2` (safe within the same descending
  # pass — style requests don't shift indices, see that function's doc).
  defp build_table_fill_requests(marker_ranges, new_tables, tables_by_index) do
    matched = marker_ranges |> Enum.sort_by(& &1.start_index) |> Enum.zip(new_tables)

    column_width_requests =
      Enum.flat_map(matched, fn {%{marker_index: idx}, table_el} ->
        table_info = Map.fetch!(tables_by_index, idx)
        column_properties = Map.get(table_info, :column_properties, [])
        table_column_width_requests(table_el["startIndex"], column_properties)
      end)

    cell_fill_requests_list =
      matched
      |> Enum.flat_map(fn {%{marker_index: idx}, table_el} ->
        table_info = Map.fetch!(tables_by_index, idx)
        cell_texts = table_info.cell_texts
        cell_runs_list = Map.get(table_info, :cell_runs, List.duplicate([], length(cell_texts)))
        cells = extract_table_cells(table_el)

        Enum.zip([cells, cell_texts, cell_runs_list])
      end)
      |> Enum.sort_by(fn {%{insert_index: idx}, _text, _runs} -> idx end, :desc)
      |> Enum.flat_map(fn {%{insert_index: idx}, text, runs} ->
        cell_fill_requests(idx, text, runs)
      end)

    column_width_requests ++ cell_fill_requests_list
  end

  defp cell_fill_requests(_idx, "", _runs), do: []

  defp cell_fill_requests(idx, text, runs),
    do: [text_insert_request(idx, text) | text_style_requests(idx, runs)]

  @doc """
  Return the range `{1, end_index}` of the current content in a Google Doc.

  Used by the Composer to pin section 0's range before any sections are appended.
  The range starts at index 1 because Google Docs body content always begins at 1.
  """
  @spec document_content_range(String.t()) :: {:ok, {1, integer()}} | {:error, term()}
  def document_content_range(doc_id) do
    with {:ok, %{body: doc}} <- get_document(doc_id) do
      {:ok, {1, document_end_index(doc)}}
    end
  end

  @doc """
  Substitute all sections' variables and image params into a Google Doc in a
  single atomic pass per phase (text then image).

  `sections` is a list of `%{position, variable_values, image_params}` maps.
  `ranges` maps each section position to its `{start_index, end_index}` in the
  document. All positions must have a range entry — section 0's range must be
  provided explicitly (use `document_content_range/1` after copy, before append).

  Each `{{key}}` placeholder in the document is matched against the section whose
  range contains it; that section's `variable_values[key]` supplies the replacement.
  Placeholders outside all section ranges are left untouched.

  Text substitution runs before image substitution (per image-substitution.md) and
  the document is re-fetched between the two phases so image indices are accurate
  after text edits. All operations within a phase are batched in a single
  batchUpdate in reverse-index order so no substitution shifts the indices of
  another.
  """
  @spec substitute_all_sections(String.t(), [map()], %{
          non_neg_integer() => {integer(), integer()}
        }) ::
          :ok | {:error, term()}
  def substitute_all_sections(doc_id, sections, ranges) do
    # Phase 1: text substitution — one fetch, one batchUpdate in reverse-index order.
    with {:ok, %{body: doc}} <- get_document(doc_id),
         {:ok, _} <- substitute_all_text(doc_id, doc, sections, ranges),
         # Phase 2: image substitution — re-fetch so indices are current after text edits.
         {:ok, %{body: doc2}} <- get_document(doc_id) do
      substitute_all_images(doc_id, doc2, sections, ranges)
    end
  end

  defp substitute_all_text(doc_id, doc, sections, ranges) do
    all_keys = sections |> Enum.flat_map(&Map.keys(&1.variable_values)) |> Enum.uniq()

    requests =
      doc
      |> body_text_runs()
      |> Enum.flat_map(&find_text_var_ranges(&1, all_keys))
      |> Enum.flat_map(fn %{key: key, start_index: s, end_index: e} = match ->
        case section_for_match(sections, ranges, match) do
          nil -> []
          section -> [{key, s, e, to_string(section.variable_values[key])}]
        end
      end)
      |> Enum.sort_by(fn {_, s, _, _} -> s end, :desc)
      |> Enum.flat_map(fn {_, s, e, value} ->
        delete = %{deleteContentRange: %{range: %{startIndex: s, endIndex: e}}}

        # Google rejects insertText with empty text, and batchUpdate is atomic —
        # one empty value would void every substitution in the batch. A blank
        # variable clears its placeholder, mirroring the image path's behavior.
        case value do
          "" -> [delete]
          _ -> [delete, %{insertText: %{location: %{index: s}, text: value}}]
        end
      end)

    maybe_batch(&batch_update/2, doc_id, requests)
  end

  defp substitute_all_images(doc_id, doc2, sections, ranges) do
    all_image_fills =
      sections
      |> Enum.flat_map(fn s ->
        fills = build_image_fills(s.image_params)
        range = Map.get(ranges, s.position)
        Enum.map(fills, fn {name, fill} -> {name, fill, range} end)
      end)

    if all_image_fills == [] do
      :ok
    else
      apply_image_fills(doc_id, doc2, all_image_fills)
    end
  end

  # Runs the actual substitution for a non-empty set of `{name, fill, range}`
  # tuples: build the Phase 1 batch (inline deletes/inserts + table creation),
  # then, if any multi-column table slots exist, fill their cells in Phase 2.
  defp apply_image_fills(doc_id, doc2, all_image_fills) do
    fills_map = Map.new(all_image_fills, fn {name, fill, _} -> {name, fill} end)
    range_by_name = Map.new(all_image_fills, fn {name, _, range} -> {name, range} end)
    content_width_pt = content_width_pt(doc2)

    filtered_ranges =
      doc2
      |> find_image_tag_ranges(Map.keys(fills_map))
      |> Enum.filter(fn %{name: name, start_index: s} ->
        in_section_range?(range_by_name, name, s)
      end)

    # Partition into table slots (image_list + columns >= 2) and inline slots.
    {table_ranges, inline_ranges} =
      Enum.split_with(filtered_ranges, fn %{name: name} ->
        fill = Map.fetch!(fills_map, name)
        fill.kind == :image_list and Map.get(fill, :columns, 1) >= 2
      end)

    # Phase 1 batch: inline slot deletes+inserts + table slot delete+insertTable.
    # Sort all requests descending by start_index so earlier inserts don't shift later ones.
    phase1_requests =
      (table_ranges ++ inline_ranges)
      |> build_image_batch_requests(fills_map, content_width_pt)

    # Snapshot pre-existing table start_indices from doc2 before Phase 1 so
    # Phase 2 can reconstruct the pre/new table interleaving (see
    # match_new_tables/3) and identify the newly inserted tables.
    pre_existing_table_starts =
      doc2 |> collect_tables() |> Enum.map(& &1["startIndex"])

    with {:ok, _} <- maybe_batch(&batch_update/2, doc_id, phase1_requests) do
      if table_ranges == [] do
        :ok
      else
        do_fill_table_cells(
          doc_id,
          table_ranges,
          fills_map,
          content_width_pt,
          pre_existing_table_starts
        )
      end
    end
  end

  # Phase 2: re-fetch the doc after table creation, locate the newly inserted
  # tables via `match_new_tables/3` (order-based, drift-proof — see its docs),
  # and fill their cells.
  defp do_fill_table_cells(
         doc_id,
         table_ranges,
         fills_map,
         content_width_pt,
         pre_existing_table_starts
       ) do
    with {:ok, %{body: doc3}} <- get_document(doc_id) do
      table_slots_asc = Enum.sort_by(table_ranges, & &1.start_index, :asc)
      slot_starts = Enum.map(table_slots_asc, & &1.start_index)

      tables_asc =
        doc3
        |> collect_tables()
        |> Enum.sort_by(fn el -> el["startIndex"] end, :asc)

      case match_new_tables(tables_asc, pre_existing_table_starts, slot_starts) do
        :mismatch ->
          Logger.warning(
            "substitute_all_images: table count mismatch in doc #{doc_id} " <>
              "(found #{length(tables_asc)} tables; expected #{length(pre_existing_table_starts)} " <>
              "pre-existing + #{length(table_slots_asc)} new); skipping Phase 2"
          )

          :ok

        {:ok, new_tables} ->
          fill_matched_tables(doc_id, table_slots_asc, new_tables, fills_map, content_width_pt)
      end
    end
  end

  # Build and run the Phase 2 batch: one insertInlineImage per cell across all
  # matched tables, paired with their slots in document order.
  defp fill_matched_tables(doc_id, table_slots_asc, new_tables, fills_map, content_width_pt) do
    phase2_requests =
      table_slots_asc
      |> Enum.zip(new_tables)
      |> Enum.flat_map(fn {%{name: name}, table_el} ->
        fill = Map.fetch!(fills_map, name)
        cols = Map.get(fill, :columns, 1)
        image_width_pt = image_width_for_columns(content_width_pt, cols)
        cells = extract_table_cells(table_el)
        fill_table_cells(cells, fill.media, %{image_width_pt: image_width_pt})
      end)

    case maybe_batch(&batch_update/2, doc_id, phase2_requests) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # Walk doc body content and collect all table StructuralElements, in
  # document order. Each returned element is the *block*, e.g.
  # `%{"startIndex" => _, "endIndex" => _, "table" => %{"rows" => _, ...}}`
  # — `startIndex`/`endIndex` are fields of the block itself, NOT of the
  # nested `"table"` object (the Docs API's `Table` resource has no
  # `startIndex` field of its own). Callers locating a table's position must
  # read `el["startIndex"]`, never `el["table"]["startIndex"]` (that always
  # returns `nil` and silently corrupts any index-based ordering built on
  # top of it — see match_new_tables/3's callers).
  defp collect_tables(doc) do
    (get_in(doc, ["body", "content"]) || [])
    |> Enum.filter(&Map.has_key?(&1, "table"))
  end

  # Extract cell insert indices from a table element returned by the Docs API.
  # Each cell's first paragraph provides the startIndex; we insert at startIndex + 1
  # (one position inside the paragraph, before any existing content).
  defp extract_table_cells(%{"table" => %{"tableRows" => rows}}) do
    for row <- rows,
        %{"tableCells" => cells} = row,
        cell <- cells do
      cell_start = get_in(cell, ["startIndex"]) || 0
      %{insert_index: cell_start + 1}
    end
  end

  defp extract_table_cells(_), do: []

  defp in_section_range?(range_by_name, name, s) do
    case Map.get(range_by_name, name) do
      nil -> false
      {rs, re} -> s >= rs and s < re
    end
  end

  # Find which section owns a given text match by checking if the match's
  # start_index falls within that section's range.
  defp section_for_match(sections, ranges, %{key: key, start_index: s}) do
    Enum.find(sections, fn section ->
      case Map.get(ranges, section.position) do
        {range_start, range_end} ->
          s >= range_start and s < range_end and Map.has_key?(section.variable_values, key)

        _ ->
          false
      end
    end)
  end

  # Walk body content and return all textRun elements as %{content, startIndex}.
  defp body_text_runs(doc) do
    (get_in(doc, ["body", "content"]) || [])
    |> Enum.flat_map(&walk_block/1)
    |> Enum.filter(&match?(%{"textRun" => _, "startIndex" => _}, &1))
  end

  @text_var_regex ~r/\{\{\s*([\p{L}\p{N}_]+)\s*\}\}/u

  # Find {{key}} occurrences in a textRun element for the given key names.
  # Returns %{key, start_index, end_index} with UTF-16 index arithmetic.
  defp find_text_var_ranges(%{"textRun" => %{"content" => content}, "startIndex" => base}, keys) do
    keys_set = MapSet.new(keys)

    Regex.scan(@text_var_regex, content, return: :index)
    |> Enum.flat_map(fn [{full_byte_start, full_byte_len}, {name_byte_start, name_byte_len}] ->
      name = binary_part(content, name_byte_start, name_byte_len)

      if MapSet.member?(keys_set, name) do
        u16_start = content |> binary_part(0, full_byte_start) |> utf16_units()
        u16_len = content |> binary_part(full_byte_start, full_byte_len) |> utf16_units()

        [%{key: name, start_index: base + u16_start, end_index: base + u16_start + u16_len}]
      else
        []
      end
    end)
  end

  defp find_text_var_ranges(_, _), do: []

  @doc """
  Delete (trash) a Google Doc. Used for best-effort cleanup after a failed composition.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec delete_document(String.t()) :: :ok | {:error, term()}
  def delete_document(doc_id) do
    with {:ok, fid} <- validate_file_id(doc_id) do
      case authenticated_request(:delete, "#{@drive_base}/files/#{fid}") do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 204}} ->
          :ok

        {:ok, %{body: body}} ->
          log_drive_error("delete failed", body)
          {:error, :delete_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  defp document_end_index(doc) do
    content = get_in(doc, ["body", "content"]) || []

    content
    |> Enum.flat_map(fn el ->
      case el do
        %{"paragraph" => %{"elements" => elements}} ->
          Enum.map(elements, &Map.get(&1, "endIndex", 0))

        _ ->
          [Map.get(el, "endIndex", 0)]
      end
    end)
    |> Enum.max(fn -> 1 end)
  end

  defp build_image_fills(image_params) when map_size(image_params) == 0, do: %{}

  defp build_image_fills(image_params) do
    Map.new(image_params, fn {name, params} ->
      kind = if Map.get(params, "kind") == "image_list", do: :image_list, else: :image
      media_items = build_media_items(params)

      fill = %{
        kind: kind,
        columns: normalize_columns(Map.get(params, "columns")),
        default_width_px: Map.get(params, "width_px") || 400,
        opacity: Map.get(params, "opacity") || 1.0,
        z_index: Map.get(params, "z_index") || 0,
        separator: normalize_separator_atom(Map.get(params, "separator") || "newline"),
        media: media_items
      }

      {name, fill}
    end)
  end

  defp normalize_columns(n) when is_integer(n), do: n |> max(1) |> min(@max_columns)

  defp normalize_columns(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> normalize_columns(i)
      :error -> 1
    end
  end

  defp normalize_columns(_), do: 1

  defp build_media_items(%{"media" => media}) when is_list(media) do
    Enum.map(media, fn m ->
      # Preserve height_px so scale_height/3 can compute aspect-ratio scaling
      # (dropping it crashed inline/columns=1 inserts with an ArithmeticError).
      %{
        uri: Map.get(m, "uri", ""),
        width_px: Map.get(m, "width_px"),
        height_px: Map.get(m, "height_px")
      }
    end)
  end

  defp build_media_items(_), do: []

  @doc false
  # Test seam: exposes build_image_fills/1 so the regression test for
  # build_media_items dropping height_px can exercise the full
  # image_params → fills conversion without touching lib code.
  def build_image_fills_for_test(image_params), do: build_image_fills(image_params)

  defp normalize_separator_atom("newline"), do: :newline
  defp normalize_separator_atom("space"), do: :space
  defp normalize_separator_atom(:newline), do: :newline
  defp normalize_separator_atom(:space), do: :space
  defp normalize_separator_atom(_), do: :none

  @doc "Get the edit URL for a Google Doc."
  @spec get_edit_url(term()) :: String.t() | nil
  def get_edit_url(doc_id) when is_binary(doc_id) and doc_id != "" do
    "https://docs.google.com/document/d/#{doc_id}/edit"
  end

  def get_edit_url(_), do: nil

  # ===========================================================================
  # Internal: Authenticated HTTP requests via PhoenixKit.Integrations
  # ===========================================================================

  @doc false
  # Public so `GoogleDocsClient.DriveWalker` can reuse the same auth +
  # auto-refresh path without duplicating credential plumbing. Not part of
  # the public API — may change without notice.
  @spec authenticated_request(atom(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def authenticated_request(method, url, opts \\ []) do
    case active_integration_uuid() do
      nil ->
        {:error, :not_configured}

      uuid ->
        integrations_backend().authenticated_request(uuid, method, url, opts)
    end
  end

  defp escape_query_value(value) do
    value |> to_string() |> String.replace("'", "\\'")
  end

  # Google Drive IDs are alphanumeric with hyphens and underscores.
  # Reject anything else to prevent URL path injection.
  @valid_file_id_pattern ~r/\A[\w-]+\z/

  @doc "Validate a Google Drive file/folder ID. Returns `{:ok, id}` or `{:error, :invalid_file_id}`."
  @spec validate_file_id(term()) :: {:ok, String.t()} | {:error, :invalid_file_id}
  def validate_file_id(id) when is_binary(id) and id != "" do
    if Regex.match?(@valid_file_id_pattern, id), do: {:ok, id}, else: {:error, :invalid_file_id}
  end

  def validate_file_id(_), do: {:error, :invalid_file_id}

  # Extract content-type from Req response headers.
  # Req >= 0.5 returns headers as %{"content-type" => ["image/png"]}.
  @allowed_thumbnail_types ~w(image/png image/jpeg image/webp image/gif)

  defp extract_content_type(%{"content-type" => [v | _]}) do
    type =
      case String.split(v, ";") do
        [type | _] -> String.trim(type)
        _ -> "image/png"
      end

    if type in @allowed_thumbnail_types do
      type
    else
      Logger.debug(
        "[DocumentCreator] thumbnail content-type downgraded | original=#{inspect(v)} → image/png"
      )

      "image/png"
    end
  end

  defp extract_content_type(_), do: "image/png"

  # Truncated logger for Drive API failure responses. The Drive/Docs API
  # error body can include the full request URL, the file ID, and a
  # multi-line error message — useful for debugging but a security and
  # log-bloat concern when shipped at scale. Truncate to a fixed length
  # so the call site is observable without leaking gigabytes when an
  # endpoint returns a giant payload.
  @drive_log_body_limit 500

  defp log_drive_error(label, body) do
    Logger.warning(
      "[DocumentCreator] #{label} | body=#{truncate_inspect(body, @drive_log_body_limit)}"
    )
  end

  defp truncate_inspect(value, limit) do
    inspected = inspect(value, limit: :infinity, printable_limit: limit)

    if String.length(inspected) > limit do
      String.slice(inspected, 0, limit) <> "…(truncated)"
    else
      inspected
    end
  end
end
