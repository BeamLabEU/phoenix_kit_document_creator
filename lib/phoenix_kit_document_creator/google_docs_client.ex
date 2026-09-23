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

  ## Configuration

  - `:page_fit_safety_pt` (float, default `8.0`) — small residual safety
    margin subtracted from a `fit: "page"` image slot's available height on
    every page it occupies, on top of the header/footer-derived body box.
    See `page_fit_safety_pt/0`.

        config :phoenix_kit_document_creator, :page_fit_safety_pt, 8.0

    Through 2026-09-22 this was a single flat constant (`130pt`) standing in
    for the whole header/footer overhang, calibrated live against one
    template. As of 2026-09-23 the top/bottom of the body is instead
    *computed* from each section's own header/footer content
    (`header_extent_pt/2`, `footer_extent_pt/2`, folded into `section_boxes/1`
    as `body_top_pt`/`body_bottom_pt`) — see `page_fit_image_list_inserts/4`.
    `page_fit_safety_pt/0` now only covers what that estimate can't see
    (line-height rounding, the little Docs adds before flowing an image vs.
    plain text) — hence the much smaller default.

    Calibrated live 2026-09-22 against Andi's landscape "Joonised
    (tootmine)" template (A4 landscape, 72pt margins, a house header — 1x2
    table with a logo — and a house footer — a rule + a details table —
    both taller than their `marginHeader`/`marginFooter` of 36pt) — these are
    the measurements the header/footer content estimator (`segment_extent_pt/2`
    and friends) is built to reproduce from `doc["headers"]`/`doc["footers"]`
    alone, without a live render:

    - text on a fresh page starts at 72pt (`marginTop`), but Docs starts an
      inline image's paragraph at ~111pt — it lays the image out under the
      header, which extends past its own margin (36pt + ~75pt of content);
      plain text is NOT pushed down the same way. `header_extent_pt/2` on
      this house header (a 1x2 table with a ~46pt-tall logo image) estimates
      ≈77pt against the ≈75pt measured live — a few points over, never under.
    - the footer extends ~68pt past its own margin: the last line of text
      that still fits lands around y≈448pt against a nominal `marginBottom`
      of 72pt (523pt). `footer_extent_pt/2` on the house footer (a rule plus
      a 2-column details table) estimates ≈67-68pt from its content alone —
      in line with that measurement.
    - the section's terminal paragraph (present after the last image, when
      the image slot ends its section) costs one more line, ~12.3pt — this
      is `page_fit_image_list_inserts/4`'s `trailing_line_pt`, applied to
      every image for simplicity rather than only the section's last one.
    - `header_extent_pt/2` / `footer_extent_pt/2` estimate a segment's
      content the same way `estimate_paragraph_height_pt/1` estimates a body
      paragraph (`fontSize × lineSpacing/100 + spaceAbove + spaceBelow`, an
      empty paragraph counting as one line), plus: a table is the sum of its
      rows, a row is the tallest of its cells, and a cell is the sum of its
      paragraphs' heights plus its own `tableCellStyle` padding (falling
      back to 5pt top/bottom — the Docs default when a table's cells don't
      set it explicitly, as seen on the house header's own cells) — and a
      paragraph holding an inline image is sized from that image's own
      `inlineObjects[id].embeddedObject.size.height` plus its own
      `marginTop`/`marginBottom` (falling back to 5pt each) instead of the
      font formula, which would drastically undersize it.
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

  # Long-side cap requested from lh3 for embedded images — see
  # `upload_image_for_embedding/3`.
  @embed_image_max_side 4096

  # Receive timeout for the over-the-cap PDF download — see
  # `export_pdf_via_export_link/1`.
  @export_link_receive_timeout 120_000

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
      # Same status check batch_update/2 got: without it a 404/403/5xx
      # error body flows into the append pipeline as a "document",
      # document_end_index/1 reads it as 1, and the appended section
      # lands at the top of the target document with no error anywhere.
      case authenticated_request(:get, "#{@docs_base}/documents/#{fid}") do
        {:ok, %{status: status} = resp} when status in 200..299 ->
          {:ok, resp}

        {:ok, %{body: body}} ->
          log_drive_error("documents.get failed", body)
          {:error, :get_document_failed}

        {:error, _} = err ->
          err
      end
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
  @default_content_height_pt 648.0
  @default_margin_pt 72.0
  @default_header_footer_margin_pt 36.0
  @max_columns 4
  @default_paragraph_font_size_pt 11.0
  @default_line_spacing_pct 115.0
  # A line's true height runs ahead of the naive fontSize × lineSpacing/100
  # product — see `estimate_paragraph_height_pt/1`'s doc for the live
  # measurement this single, safe-side constant is calibrated against.
  @font_leading 1.22
  # Fallback padding used by the header/footer content estimator
  # (`segment_extent_pt/2` and friends) when the API doesn't give us a more
  # specific number — see the moduledoc's `Configuration` section.
  @default_cell_padding_pt 5.0
  @inline_image_padding_pt 5.0
  # One default-style line's worth of the section's terminal paragraph,
  # applied to every `fit: "page"` image for simplicity — see
  # `page_fit_image_list_inserts/4`.
  @page_fit_trailing_line_pt @default_paragraph_font_size_pt *
                               (@default_line_spacing_pct / 100.0) * @font_leading

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
  Per-section content boxes for a Google Doc — one per `sectionBreak` in its
  body, each covering the character range from that break up to the next
  (or the end of the body).

  A `sectionBreak` StructuralElement's own `sectionStyle` describes the
  section that STARTS right after it (see `first_section_style/1`'s doc for
  why the body's very first element is always one of these). `width_pt` /
  `height_pt` are that section's own page content area — `documentStyle`'s
  `pageSize`, swapped when the section's resolved `flipPageOrientation` is
  true (section value if the key is present, else the document's, else
  `false` — same resolution `section_flip?/2` uses for "does the section
  look landscape"), minus that section's own margins (its `sectionStyle`,
  else `documentStyle`, else 72pt — the same resolution `content_width_pt/1`
  and `section_margin_requests/2` use). `margin_top` / `margin_bottom` are
  exposed so callers (the `fit: "page"` image scaling in `apply_image_fills/3`)
  can reserve space without re-deriving them.

  A document with no explicit `sectionBreak` yields a single box for the
  whole body, using `documentStyle` alone; when `pageSize` is missing too it
  falls back to the same constants `content_width_pt/1` uses — 468pt width
  (documented as "Letter, 1in margins"), and 648pt height (Letter's 792pt
  minus the same 144pt of margin).

  `body_top_pt` / `body_bottom_pt` are the top/bottom of the area a `fit:
  "page"` image can actually use — computed from the section's header/footer
  *content* (`header_extent_pt/2`, `footer_extent_pt/2`), not just its
  `marginTop`/`marginBottom`: `body_top_pt = max(margin_top, margin_header +
  header_extent)`, `body_bottom_pt = page_h_effective - max(margin_bottom,
  margin_footer + footer_extent)`. A header/footer taller than its own
  margin pushes the body down/up further than the nominal margin would; one
  no taller than its margin leaves the nominal margin as-is. See the
  moduledoc's `Configuration` section for the live measurement this
  reproduces.
  """
  @spec section_boxes(map()) :: [
          %{
            start_index: non_neg_integer(),
            end_index: non_neg_integer(),
            width_pt: float(),
            height_pt: float(),
            margin_top: float(),
            margin_bottom: float(),
            body_top_pt: float(),
            body_bottom_pt: float()
          }
        ]
  def section_boxes(doc) when is_map(doc) do
    document_style = Map.get(doc, "documentStyle") || %{}

    breaks =
      doc
      |> get_in(["body", "content"])
      |> List.wrap()
      |> Enum.filter(&Map.has_key?(&1, "sectionBreak"))

    doc_end = document_end_index(doc)

    case breaks do
      [] ->
        [build_section_box(doc, %{}, document_style, 0, doc_end)]

      breaks ->
        breaks
        |> Enum.with_index()
        |> Enum.map(&section_box_for_break(&1, breaks, doc, document_style, doc_end))
    end
  end

  defp section_box_for_break({sb, i}, breaks, doc, document_style, doc_end) do
    style = get_in(sb, ["sectionBreak", "sectionStyle"]) || %{}
    start_index = Map.get(sb, "startIndex", 0)

    end_index =
      case Enum.at(breaks, i + 1) do
        nil -> doc_end
        next -> Map.get(next, "startIndex", doc_end)
      end

    build_section_box(doc, style, document_style, start_index, end_index)
  end

  defp build_section_box(doc, section_style, document_style, start_index, end_index) do
    flip = resolve_flip(section_style, document_style)
    page_size = Map.get(document_style, "pageSize") || %{}
    raw_w = magnitude(Map.get(page_size, "width"))
    raw_h = magnitude(Map.get(page_size, "height"))
    {page_w, page_h} = if flip, do: {raw_h, raw_w}, else: {raw_w, raw_h}

    margin_top = section_margin(section_style, document_style, "marginTop")
    margin_bottom = section_margin(section_style, document_style, "marginBottom")
    margin_left = section_margin(section_style, document_style, "marginLeft")
    margin_right = section_margin(section_style, document_style, "marginRight")
    margin_header = header_footer_margin(section_style, document_style, "marginHeader")
    margin_footer = header_footer_margin(section_style, document_style, "marginFooter")

    width_pt =
      if is_number(page_w),
        do: page_w - margin_left - margin_right,
        else: @default_content_width_pt

    height_pt =
      if is_number(page_h),
        do: page_h - margin_top - margin_bottom,
        else: @default_content_height_pt

    # Same fallback `content_width_pt/1`'s sibling above uses: when the API
    # gives us no `pageSize` at all, assume the page is exactly margins +
    # the default content box, so body_bottom_pt lines up with height_pt.
    effective_page_h =
      if is_number(page_h),
        do: page_h,
        else: margin_top + margin_bottom + @default_content_height_pt

    header_extent = header_extent_pt(doc, section_style)
    footer_extent = footer_extent_pt(doc, section_style)

    %{
      start_index: start_index,
      end_index: end_index,
      width_pt: width_pt,
      height_pt: height_pt,
      margin_top: margin_top,
      margin_bottom: margin_bottom,
      body_top_pt: max(margin_top, margin_header + header_extent),
      body_bottom_pt: effective_page_h - max(margin_bottom, margin_footer + footer_extent)
    }
  end

  defp section_margin(section_style, document_style, field) do
    magnitude(Map.get(section_style, field) || Map.get(document_style, field)) ||
      @default_margin_pt
  end

  defp header_footer_margin(section_style, document_style, field) do
    magnitude(Map.get(section_style, field) || Map.get(document_style, field)) ||
      @default_header_footer_margin_pt
  end

  @doc """
  Estimated height in points of the header that resolves for `section_style`
  (its own `defaultHeaderId`, else the document's — same resolution Docs
  itself uses for inheritance) — `0.0` when neither has one. See the
  moduledoc's `Configuration` section for the estimator's rules and the live
  measurement it's calibrated against.
  """
  @spec header_extent_pt(map(), map()) :: float()
  def header_extent_pt(doc, section_style) when is_map(doc) and is_map(section_style) do
    header_footer_extent_pt(doc, section_style, "headers", "defaultHeaderId")
  end

  @doc """
  Same as `header_extent_pt/2`, for the footer that resolves for
  `section_style`.
  """
  @spec footer_extent_pt(map(), map()) :: float()
  def footer_extent_pt(doc, section_style) when is_map(doc) and is_map(section_style) do
    header_footer_extent_pt(doc, section_style, "footers", "defaultFooterId")
  end

  defp header_footer_extent_pt(doc, section_style, container_key, id_key) do
    document_style = Map.get(doc, "documentStyle") || %{}
    id = Map.get(section_style, id_key) || Map.get(document_style, id_key)

    case id && get_in(doc, [container_key, id, "content"]) do
      nil -> 0.0
      content -> segment_extent_pt(doc, content)
    end
  end

  # Sum of estimated heights of the top-level structural elements
  # (paragraphs, tables) of a header/footer segment, or of a table cell's
  # own `content`.
  defp segment_extent_pt(doc, elements) do
    elements
    |> List.wrap()
    |> Enum.map(&element_extent_pt(doc, &1))
    |> Enum.sum()
  end

  defp element_extent_pt(doc, %{"paragraph" => paragraph}),
    do: paragraph_extent_pt(doc, paragraph)

  defp element_extent_pt(doc, %{"table" => table}), do: table_extent_pt(doc, table)
  defp element_extent_pt(_doc, _), do: 0.0

  # A paragraph holding an inline image is sized from the image's own
  # height (plus its own embeddedObject margins) rather than the font-size
  # formula, which would badly undersize a header/footer logo row.
  defp paragraph_extent_pt(doc, paragraph) do
    image_heights =
      paragraph
      |> Map.get("elements", [])
      |> Enum.map(&inline_image_extent_pt(doc, &1))
      |> Enum.reject(&is_nil/1)

    case image_heights do
      [] -> estimate_paragraph_height_pt(%{"paragraph" => paragraph})
      heights -> Enum.sum(heights)
    end
  end

  defp inline_image_extent_pt(doc, %{"inlineObjectElement" => %{"inlineObjectId" => id}}) do
    embedded =
      get_in(doc, ["inlineObjects", id, "inlineObjectProperties", "embeddedObject"]) || %{}

    case magnitude(get_in(embedded, ["size", "height"])) do
      nil ->
        nil

      height ->
        height + inline_image_padding(embedded, "marginTop") +
          inline_image_padding(embedded, "marginBottom")
    end
  end

  defp inline_image_extent_pt(_doc, _), do: nil

  defp inline_image_padding(embedded, field) do
    magnitude(Map.get(embedded, field)) || @inline_image_padding_pt
  end

  defp table_extent_pt(doc, table) do
    table
    |> Map.get("tableRows", [])
    |> Enum.map(&table_row_extent_pt(doc, &1))
    |> Enum.sum()
  end

  defp table_row_extent_pt(doc, row) do
    case row |> Map.get("tableCells", []) |> Enum.map(&table_cell_extent_pt(doc, &1)) do
      [] -> 0.0
      heights -> Enum.max(heights)
    end
  end

  defp table_cell_extent_pt(doc, cell) do
    style = Map.get(cell, "tableCellStyle") || %{}
    padding_top = magnitude(Map.get(style, "paddingTop")) || @default_cell_padding_pt
    padding_bottom = magnitude(Map.get(style, "paddingBottom")) || @default_cell_padding_pt
    border_top = magnitude(get_in(style, ["borderTop", "width"])) || 0.0
    border_bottom = magnitude(get_in(style, ["borderBottom", "width"])) || 0.0

    segment_extent_pt(doc, Map.get(cell, "content", [])) + padding_top + padding_bottom +
      border_top + border_bottom
  end

  # Section value if the key is present (even `false`), else the document's,
  # else `false` — same resolution `template_flip?/1` uses (kept separate to
  # avoid coupling section_boxes/1 to append_template/3's document shape).
  defp resolve_flip(section_style, document_style) do
    case Map.fetch(section_style, "flipPageOrientation") do
      {:ok, flip} when is_boolean(flip) -> flip
      _ -> Map.get(document_style, "flipPageOrientation", false)
    end
  end

  # Finds the box whose [start_index, end_index) range contains `index`.
  defp box_for_index(boxes, index) do
    Enum.find(boxes, fn box -> index >= box.start_index and index < box.end_index end)
  end

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
  `lh3.googleusercontent.com/d/<id>=s4096` URL that Google's image fetcher
  can read without following a redirect.

  The `=s4096` suffix matters: a bare `lh3…/d/<id>` serves a copy scaled
  down to 1600px on the long side, so every larger image lost detail in the
  document and its PDF (a 4000×2884 upload reached the PDF as 1600×1154).
  `=sN` returns the original bytes when the long side is at most N and never
  enlarges; 4096 rather than `=s0` because `insertInlineImage` rejects
  images over 25 megapixels, and a 4096px long side stays under that for
  any aspect ratio. Google's own PDF export stores images at up to 2500px on
  the long side, so 4096 loses nothing there.

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
            # INVALID_ARGUMENT. The size suffix is explained in the @doc.
            {:ok, "https://lh3.googleusercontent.com/d/#{file_id}=s#{@embed_image_max_side}"}

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

          # A 404 on the PATCH is ambiguous: the file was just fetched above,
          # so the missing resource is most likely the DESTINATION folder.
          # Keep it distinct from :drive_file_not_found (initial GET 404) so
          # callers can treat "file already gone" and "bad destination"
          # differently — conflating them once let deletes DB-trash entries
          # whose live Drive files then got resurrected by the next sync.
          {:ok, %{status: 404, body: body}} ->
            log_drive_error("move failed (404, likely destination folder)", body)
            {:error, :move_failed}

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

  @doc """
  Export a Google Doc as PDF. Returns `{:ok, pdf_binary}`.

  On failure the reason names why Drive refused the export instead of
  collapsing every case into `:pdf_export_failed`:

    * `:drive_file_not_found` — Drive returned 404. Usually the file was
      deleted, but Drive also answers 404 for a live file the current
      connection is not allowed to see (an unshare, or a re-pointed
      Google connection), so callers must not treat it as proof the file
      is gone.
    * `:drive_forbidden` — Drive returned 403 because the connected
      Google account lacks permission to read the file
    * `:drive_rate_limited` — Drive returned 403 because of a rate/quota
      limit (retrying later can succeed)
    * `:drive_export_too_large` — the Doc is past the export endpoint's
      size cap (about 10 MB of PDF) AND the fallback below failed too
    * `:pdf_export_failed` — any other non-200 response, including a 403
      with an unrecognized reason

  Past that cap `files.export` answers 403 `exportSizeLimitExceeded`; the
  same PDF is then downloaded from the file's `exportLinks` (a
  `docs.google.com` URL that has no such cap) with the same credentials.
  The token is only ever sent to an `https://docs.google.com` link.
  """
  @spec export_pdf(String.t()) ::
          {:ok, binary()}
          | {:error,
             :invalid_file_id
             | :drive_export_too_large
             | :drive_file_not_found
             | :drive_forbidden
             | :drive_rate_limited
             | :pdf_export_failed
             | term()}
  def export_pdf(doc_id) do
    with {:ok, fid} <- validate_file_id(doc_id) do
      case authenticated_request(:get, "#{@drive_base}/files/#{fid}/export",
             params: [mimeType: "application/pdf"]
           ) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          {:ok, body}

        {:ok, %{status: 404, body: body}} ->
          log_drive_error("PDF export failed", body)
          {:error, :drive_file_not_found}

        {:ok, %{status: 403, body: body}} ->
          export_pdf_forbidden(fid, body)

        {:ok, %{body: body}} ->
          log_drive_error("PDF export failed", body)
          {:error, :pdf_export_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  defp export_pdf_forbidden(fid, body) do
    case classify_403(body, :pdf_export_failed) do
      :drive_export_too_large ->
        export_pdf_via_export_link(fid)

      reason ->
        log_drive_error("PDF export failed", body)
        {:error, reason}
    end
  end

  # `files.export` refuses documents whose PDF is past ~10 MB — a few
  # full-resolution photos are enough. The file's `exportLinks` PDF URL
  # serves the same export without that cap.
  #
  # The body must start with the `%PDF-` magic: docs.google.com answers
  # some auth and interstitial failures with a 200 HTML page, which would
  # otherwise be handed to the caller as a PDF. The longer receive timeout
  # is because every document reaching this path renders to over 10 MB,
  # which can outlast Req's 15s default.
  defp export_pdf_via_export_link(fid) do
    with {:ok, %{status: 200, body: %{"exportLinks" => %{"application/pdf" => link}}}}
         when is_binary(link) <-
           authenticated_request(:get, "#{@drive_base}/files/#{fid}",
             params: [fields: "exportLinks"]
           ),
         %URI{scheme: "https", host: "docs.google.com"} <- URI.parse(link),
         {:ok, %{status: 200, body: "%PDF-" <> _ = pdf}} <-
           authenticated_request(:get, link, receive_timeout: @export_link_receive_timeout) do
      {:ok, pdf}
    else
      other ->
        log_drive_error("PDF export past the size cap, export link fallback failed", other)
        {:error, :drive_export_too_large}
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

  Inserts a section break (next page), then the content of `template_doc_id`
  into `target_doc_id`, then gives the new section the template's own page
  margins. Returns `{:ok, {start_index, end_index}}` representing the
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
       reused as-is), and fill every cell with its captured text, character
       and paragraph style, and column widths (`build_table_fill_requests/3`,
       private) in one batchUpdate. Any `{{var}}`
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
  `updateTextStyle` in the same batch as the corresponding `insertText`
  (after that text's paragraph style — see below). Every inserted character
  is covered by an explicit range, including `bold: false`/`italic: false`
  for plain runs, so freshly inserted text can never silently inherit
  formatting from neighboring content already in the target document.

  Paragraph-level style — alignment, line spacing, space above/below, named
  style type (headings), start/first-line indentation — is captured the
  same way and replayed via `updateParagraphStyle`
  (`paragraph_style_requests/2`), same anti-inheritance guarantee: every
  field is always in the mask — with the template's value, or unset so it
  resolves against the paragraph's named style in the target document.
  Paragraph style is always sent BEFORE character style
  (`paragraph_then_text_style_requests/3`): an `updateParagraphStyle` whose
  mask includes `namedStyleType` resets the paragraph's text style, even
  when the named style doesn't change, so the opposite order silently
  stripped every appended section of its font sizes and bold. That reset is
  not in Google's public API reference — verified live 2026-09-21, and no
  mock-based test can guard it. List bullets are replayed via
  `createParagraphBullets` (`paragraph_bullet_requests/2`), resolving
  bulleted vs numbered from the source and mapping to Google's own default
  preset for that family — this reproduces glyph *family*, not an arbitrary
  custom glyph/format exactly (see `extract_bullet_info/2`'s doc).

  Each appended template becomes its own document SECTION: the content is
  preceded by `insertSectionBreak` (`NEXT_PAGE`, so it still starts on a new
  page) rather than a page break, and the section then gets the template's
  own page margins AND orientation via `updateSectionStyle`
  (`section_layout_requests/3`). Margins are a document-level setting
  otherwise, so a contract laid out for 72pt margins used to be poured into
  whatever the first template's were. The margins ride in the same atomic
  batch as the content, on purpose: a composed document with the wrong
  margins is the very defect this exists to prevent, so a margin request
  Google rejects fails the append (and the compose) loudly rather than
  leaving a quietly mis-laid-out document behind. Traps (the first two
  verified live 2026-09-21):

    * A section break inserts a newline ahead of itself, so the appended
      content starts at `insert_index + 2` — in a fresh, empty paragraph of
      the new section. That fresh paragraph is what makes paragraph-level
      styling safe for the section's own first paragraph:
      `updateParagraphStyle`/`createParagraphBullets` target whole
      paragraphs, and content that merely continued the target's last
      paragraph would reformat the preceding section's trailing text too.
      (The target's closing character is the document's shared terminal
      marker, not a shiftable paragraph separator — a page break alone, an
      inline element, never split it, which is why this used to insert its
      own `"\\n"` first.)
    * `updateDocumentStyle` on margins overwrites the margins of EVERY
      section, silently. Nothing here sends it; anything that ever does must
      run before the section margins are set.
    * Page SIZE is document-wide; page ORIENTATION is per section via
      `flipPageOrientation`, relative to the document's `pageSize` — hence
      the XOR against the target's page shape in `section_layout_requests/3`.
      `flipPageOrientation` must always carry a concrete boolean when it's
      sent — the API requires "setting a concrete value"; unsetting it
      results in a 400 — so every appended section states it explicitly,
      including `false`, or it silently inherits the previous section's
      flip.

  Known limitations: cell shading, borders, and merged cells are not
  restored — `insertTable` creates a bare table beyond the column widths
  above. Nested tables (a table inside a table cell) are not supported.

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
         {text, tables, body_runs, body_paragraphs} =
           flatten_template_with_table_markers_and_styles(template_doc),
         {:ok, %{body: current_doc}} <- get_fn.(target_doc_id) do
      end_index = document_end_index(current_doc)
      insert_index = max(end_index - 1, 1)
      content_start = insert_index + 2

      # insertSectionBreak puts a newline ahead of itself, so content_start
      # lands in the new section's own fresh paragraph — see this function's
      # doc. The section margins are position-independent within the batch
      # (the new section always holds at least its terminal paragraph, and
      # nothing in the batch moves content_start); last by convention.
      requests =
        [
          %{insertSectionBreak: %{location: %{index: insert_index}, sectionType: "NEXT_PAGE"}},
          %{insertText: %{location: %{index: content_start}, text: text}}
        ] ++
          paragraph_then_text_style_requests(content_start, body_paragraphs, body_runs) ++
          clear_inherited_bullets(content_start, text) ++
          paragraph_bullet_requests(content_start, body_paragraphs) ++
          section_layout_requests(content_start, template_doc, current_doc)

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
  one entry per table cell — the same order `extract_table_cells/1` and the
  cell-fill phase (`build_table_fill_requests/3`, both private) enumerate
  cells in.

  Nested tables (a table inside a table cell) are not supported: a cell's
  text is captured from its paragraph blocks only, same limitation the
  top-level flatten has.

  This is a thin wrapper around `flatten_template_with_table_markers_and_styles/1`
  that drops its 3rd/4th return values (`body_runs`/`body_paragraphs`) — kept
  at its original 2-tuple arity so existing callers are unaffected by the
  style-capture addition.
  """
  @spec flatten_template_with_table_markers(map()) :: {String.t(), [map()]}
  def flatten_template_with_table_markers(doc) do
    {text, tables, _body_runs, _body_paragraphs} =
      flatten_template_with_table_markers_and_styles(doc)

    {text, tables}
  end

  @doc """
  Same walk as `flatten_template_with_table_markers/1`, additionally
  capturing per-run character style (bold, italic, font size, foreground
  color) and per-paragraph style (alignment, line spacing, space
  above/below, named style type, indentation, list bullet) — see
  `append_template/3`'s "Formatting fidelity" doc section.

  Returns `{text, tables, body_runs, body_paragraphs}`:

    * `text`, `tables` — identical to `flatten_template_with_table_markers/1`,
      except each table map in `tables` gains three keys: `column_properties`
      (the source table's `tableStyle.tableColumnProperties`, normalized to
      `%{width_type, magnitude, unit}`, one per column, `[]` if the source
      table has none), `cell_runs` (one run-list per cell, parallel to
      `cell_texts`, same order — see `text_style_requests/2`'s run shape) and
      `cell_paragraphs` (one paragraph-span-list per cell, parallel to
      `cell_texts`, same order — see `paragraph_style_requests/2`'s span
      shape).
    * `body_runs` — the non-table body text's per-run style spans, same run
      shape as a `cell_runs` entry, with `start_offset`/`length` in UTF-16
      units relative to the start of `text` (table markers consume offset
      but contribute no run — they're deleted before any style request
      referencing them would apply).
    * `body_paragraphs` — the non-table body text's per-paragraph style
      spans, same shape as a `cell_paragraphs` entry, offsets relative to the
      start of `text`.
  """
  @spec flatten_template_with_table_markers_and_styles(map()) ::
          {String.t(), [map()], [map()], [map()]}
  def flatten_template_with_table_markers_and_styles(doc) do
    blocks = get_in(doc, ["body", "content"]) |> List.wrap()
    doc_lists = get_in(doc, ["lists"]) || %{}

    {rev_chunks, rev_tables, rev_body_runs, rev_body_paragraphs, _next_marker, _offset} =
      Enum.reduce(blocks, {[], [], [], [], 1, 0}, &flatten_block_with_styles(&1, &2, doc_lists))

    text = rev_chunks |> Enum.reverse() |> Enum.join()

    {text, Enum.reverse(rev_tables), Enum.reverse(rev_body_runs),
     Enum.reverse(rev_body_paragraphs)}
  end

  defp flatten_block_with_styles(
         %{"paragraph" => %{"elements" => elements} = paragraph},
         {chunks, tables, body_runs, body_paragraphs, n, offset},
         doc_lists
       ) do
    runs = text_runs_with_styles(elements, offset)
    para_text = Enum.map_join(runs, & &1.text)
    length = utf16_units(para_text)
    new_offset = offset + length
    span = paragraph_span(paragraph, offset, length, doc_lists)

    {[para_text | chunks], tables, Enum.reverse(runs) ++ body_runs, [span | body_paragraphs], n,
     new_offset}
  end

  defp flatten_block_with_styles(
         %{"table" => table},
         {chunks, tables, body_runs, body_paragraphs, n, offset},
         doc_lists
       ) do
    {rows, columns} = table_dimensions(table)
    table_rows = Map.get(table, "tableRows", [])

    # Each row is normalized to exactly `columns` entries: merged cells make
    # source rows narrower than the declared column count, but insertTable
    # always creates a rectangular table and the fill phase zips captured
    # cells against it positionally — a short row would shift every later
    # cell's content left by one, silently. Padded cells are "" and get no
    # fill requests.
    cell_texts = Enum.flat_map(table_rows, &normalize_row(row_cell_texts(&1), columns, ""))
    cell_runs = Enum.flat_map(table_rows, &normalize_row(row_cell_runs(&1), columns, []))

    cell_paragraphs =
      Enum.flat_map(table_rows, &normalize_row(row_cell_paragraphs(&1, doc_lists), columns, []))

    column_properties = extract_column_properties(table)

    table_info = %{
      marker_index: n,
      rows: rows,
      columns: columns,
      cell_texts: cell_texts,
      cell_runs: cell_runs,
      cell_paragraphs: cell_paragraphs,
      column_properties: column_properties
    }

    marker = table_marker(n)
    new_offset = offset + utf16_units(marker)

    {[marker | chunks], [table_info | tables], body_runs, body_paragraphs, n + 1, new_offset}
  end

  defp flatten_block_with_styles(_block, acc, _doc_lists), do: acc

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

  # Pad (or trim) one captured row to the table's declared column count so
  # the row-major cell lists always align positionally with the rectangular
  # table `insertTable` creates. See the call sites in
  # `flatten_block_with_styles/3`.
  defp normalize_row(cells, columns, filler) do
    case length(cells) do
      n when n < columns -> cells ++ List.duplicate(filler, columns - n)
      n when n > columns -> Enum.take(cells, columns)
      _ -> cells
    end
  end

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

  defp row_cell_paragraphs(%{"tableCells" => cells}, doc_lists),
    do: Enum.map(cells, &cell_paragraph_spans(&1, doc_lists))

  defp row_cell_paragraphs(_, _doc_lists), do: []

  # Per-paragraph style variant of `cell_style_runs/1` — walks the cell's own
  # paragraph blocks (not flattened across them, since each one needs its
  # own captured `paragraphStyle`/`bullet`), offsets local to the cell
  # starting at 0. Deliberately does NOT mirror `cell_style_runs/1`'s
  # trailing-newline strip: unlike a run's `text`/`length` (which must match
  # what the cell fill actually inserts, see `cell_fill_requests/4`), a paragraph's natural,
  # un-stripped length already lands the style range exactly where the
  # paragraph ends up structurally in the target — the cell's last paragraph
  # reuses the pre-existing bare cell's own trailing newline instead of
  # having one inserted, and that pre-existing newline occupies exactly the
  # one UTF-16 unit the un-stripped length accounts for. See
  # `paragraph_style_requests/2`'s doc for the general rule.
  defp cell_paragraph_spans(%{"content" => content}, doc_lists) do
    {rev_spans, _offset} =
      Enum.reduce(content, {[], 0}, fn
        %{"paragraph" => paragraph}, {spans, offset} ->
          elements = paragraph["elements"] || []

          para_text =
            Enum.map_join(elements, fn el -> get_in(el, ["textRun", "content"]) || "" end)

          length = utf16_units(para_text)
          span = paragraph_span(paragraph, offset, length, doc_lists)
          {[span | spans], offset + length}

        _other, acc ->
          acc
      end)

    Enum.reverse(rev_spans)
  end

  defp cell_paragraph_spans(_, _doc_lists), do: []

  # A `paragraphStyle` key Google omits is NOT "the API default" — it means
  # the paragraph inherits that property from its named style (a template
  # whose NORMAL_TEXT says 115% line spacing, a heading relying on
  # HEADING_1's own space above/below). It is captured as `nil` and replayed
  # as an explicit *unset* (see `paragraph_style_requests/2`), which still
  # gives the anti-inheritance guarantee: a freshly inserted/split paragraph
  # can never silently keep alignment/spacing from whatever paragraph sat at
  # the insertion point. Substituting a concrete default here instead (as
  # this used to: START / 100% / zero spacing) flattened every appended
  # section's spacing to values its template never asked for.
  #
  # `namedStyleType` alone keeps a concrete fallback — every paragraph has
  # one, and it is what the unset properties resolve against.
  @default_named_style_type "NORMAL_TEXT"

  defp paragraph_span(paragraph, start_offset, length, doc_lists) do
    %{
      start_offset: start_offset,
      length: length,
      style: extract_paragraph_style(paragraph, doc_lists),
      bullet: extract_bullet_info(paragraph, doc_lists)
    }
  end

  # NB an unset property resolves against the TARGET document's named
  # styles. The target is a copy of the first template, and later templates'
  # named-style definitions are not carried over, so the replay matches the
  # template exactly only where the two documents' named styles agree.
  defp extract_paragraph_style(paragraph, _doc_lists) do
    style = Map.get(paragraph, "paragraphStyle", %{})

    %{
      alignment: Map.get(style, "alignment"),
      line_spacing: numeric_or_nil(Map.get(style, "lineSpacing")),
      space_above: dimension_or_nil(Map.get(style, "spaceAbove")),
      space_below: dimension_or_nil(Map.get(style, "spaceBelow")),
      named_style_type: Map.get(style, "namedStyleType", @default_named_style_type),
      indent_start: dimension_or_nil(Map.get(style, "indentStart")),
      indent_first_line: dimension_or_nil(Map.get(style, "indentFirstLine"))
    }
  end

  defp numeric_or_nil(n) when is_number(n), do: n * 1.0
  defp numeric_or_nil(_), do: nil

  # Only an ABSENT key means "inherit". A dimension that is present but
  # carries no magnitude — `%{"unit" => "PT"}` — is an explicit zero: the API
  # omits a zero `magnitude` from its JSON (verified live 2026-09-21: a
  # HEADING_1 paragraph whose space above was set to 0pt reads back as
  # `"spaceAbove" => %{"unit" => "PT"}`, one that inherits it has no
  # `spaceAbove` key at all). Reading it as "inherit" would hand a heading
  # its named style's spacing back after the template author removed it.
  defp dimension_or_nil(%{"magnitude" => m} = dimension) when is_number(m) do
    %{magnitude: m * 1.0, unit: Map.get(dimension, "unit", "PT")}
  end

  defp dimension_or_nil(%{"unit" => unit}) when is_binary(unit),
    do: %{magnitude: 0.0, unit: unit}

  defp dimension_or_nil(_), do: nil

  # List membership: only glyph *family* (bulleted vs numbered) is
  # reproduced, via Google's own default preset for that family
  # (`BULLET_DISC_CIRCLE_SQUARE` / `NUMBERED_DECIMAL_ALPHA_ROMAN`) — not the
  # source list's exact glyph/format at each nesting level. `createParagraphBullets`
  # only accepts a fixed enum of ~20 presets, so reproducing a custom glyph
  # sequence exactly would require matching the source's per-level
  # glyphType/glyphSymbol against every preset's own known sequence; for the
  # overwhelming common case (a list created via the Docs UI's default
  # "bulleted list"/"numbered list" buttons) this already matches exactly,
  # and is a documented approximation, not silent data loss, for the rest.
  @numbered_glyph_types ~w(DECIMAL ZERO_DECIMAL UPPER_ALPHA ALPHA UPPER_ROMAN ROMAN)

  defp extract_bullet_info(%{"bullet" => %{"listId" => list_id} = bullet}, doc_lists) do
    level = Map.get(bullet, "nestingLevel", 0)
    %{list_id: list_id, preset: resolve_bullet_preset(list_id, level, doc_lists)}
  end

  defp extract_bullet_info(_paragraph, _doc_lists), do: nil

  defp resolve_bullet_preset(list_id, level, doc_lists) do
    nesting_levels = get_in(doc_lists, [list_id, "listProperties", "nestingLevels"]) || []

    case Enum.at(nesting_levels, level) do
      %{"glyphType" => glyph_type} when glyph_type in @numbered_glyph_types ->
        "NUMBERED_DECIMAL_ALPHA_ROMAN"

      _ ->
        "BULLET_DISC_CIRCLE_SQUARE"
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
  (same convention as `collect_text_replacements/3` and
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

  @section_margin_fields ~w(marginTop marginBottom marginLeft marginRight marginHeader marginFooter)

  @doc """
  Builds the `updateSectionStyle` request that gives an appended section its
  template's own page margins. `section_index` is any index inside the
  section — `append_template/3` passes the section's `content_start`.

  The margins are the ones the template's own first page renders with: its
  first section's `sectionStyle.margin*` where set, else
  `documentStyle.margin*` — the API's own resolution order (a section margin
  left unset defaults to the document's). A template that is itself a
  composed document carries per-section margins this way, and reading
  `documentStyle` alone would hand its first section the wrong ones.

  Only the margins the template actually states are touched; a margin
  present without a magnitude is an explicit zero (the API omits a zero
  magnitude from its JSON — see `dimension_or_nil/1`). No margins in either
  place produces no request.
  """
  @spec section_margin_requests(non_neg_integer(), map()) :: [map()]
  def section_margin_requests(section_index, template_doc) do
    document_style = Map.get(template_doc, "documentStyle") || %{}
    section_style = first_section_style(template_doc)
    margins = margin_fields(section_style, document_style)

    case margins do
      [] ->
        []

      margins ->
        [
          %{
            "updateSectionStyle" => %{
              "range" => %{"startIndex" => section_index, "endIndex" => section_index + 1},
              "sectionStyle" => Map.new(margins),
              "fields" => Enum.map_join(margins, ",", &elem(&1, 0))
            }
          }
        ]
    end
  end

  @doc """
  Builds the single `updateSectionStyle` request that gives an appended
  section both its template's own page margins (same resolution as
  `section_margin_requests/2`, which this reuses) and its page ORIENTATION,
  relative to the target document's page size. `target_doc` is the
  already-fetched target document (`append_template/3`'s `current_doc`).

  Google Docs stores page SIZE document-wide — a section cannot have its own
  `pageSize` — but page ORIENTATION is per section, via
  `SectionStyle.flipPageOrientation`, always resolved relative to
  `DocumentStyle.pageSize`. A template's own "true" orientation is therefore
  derived, not read off a single field: Google records landscape either as a
  literally wide `pageSize` (width > height) or as a portrait-shaped
  `pageSize` plus `flipPageOrientation: true` (section-level if the template
  itself is a composed document, else document-level) — `landscape_shaped?`
  XOR the resolved flip covers both. The section this function builds a
  request for then gets the flip that makes it look, against the TARGET
  document's own (unflipped) page shape, the way the template actually looks:
  `template_landscape? XOR target_landscape_shaped?`.

  `flipPageOrientation` is ALWAYS in the request with a concrete boolean —
  never omitted, including `false` — in the same `updateSectionStyle` and
  mask as the margins. The API requires "setting a concrete value" for this
  field; unsetting it results in a 400, and omitting the request entirely
  would let the section silently inherit whatever flip the previous section
  (or the document) carries — the exact defect this exists to prevent when a
  portrait template follows a landscape one.
  """
  @spec section_layout_requests(non_neg_integer(), map(), map()) :: [map()]
  def section_layout_requests(section_index, template_doc, target_doc) do
    document_style = Map.get(template_doc, "documentStyle") || %{}
    section_style = first_section_style(template_doc)
    margins = margin_fields(section_style, document_style)
    flip = section_flip?(template_doc, target_doc)

    style = margins |> Map.new() |> Map.put("flipPageOrientation", flip)
    fields = Enum.map_join(margins ++ [{"flipPageOrientation", flip}], ",", &elem(&1, 0))

    [
      %{
        "updateSectionStyle" => %{
          "range" => %{"startIndex" => section_index, "endIndex" => section_index + 1},
          "sectionStyle" => style,
          "fields" => fields
        }
      }
    ]
  end

  defp margin_fields(section_style, document_style) do
    Enum.flat_map(@section_margin_fields, fn field ->
      case dimension_or_nil(Map.get(section_style, field) || Map.get(document_style, field)) do
        nil -> []
        dimension -> [{field, dimension_payload(dimension)}]
      end
    end)
  end

  # section_flip = template_landscape? XOR target_landscape_shaped? — see
  # section_layout_requests/3's doc. Booleans, so XOR is plain `!=`.
  defp section_flip?(template_doc, target_doc) do
    template_page_size = get_in(template_doc, ["documentStyle", "pageSize"])
    target_page_size = get_in(target_doc, ["documentStyle", "pageSize"])

    template_landscape? = landscape_shaped?(template_page_size) != template_flip?(template_doc)
    target_landscape_shaped? = landscape_shaped?(target_page_size)

    template_landscape? != target_landscape_shaped?
  end

  # first_section_style's flipPageOrientation, if explicitly present (even
  # `false` — a composed template's own section can override its document),
  # else the template's documentStyle.flipPageOrientation, else false.
  # Map.get/2 with `||` would treat an explicit `false` as absent, so this
  # uses Map.fetch/2 to tell "unset" from "set to false" apart.
  defp template_flip?(template_doc) do
    section_style = first_section_style(template_doc)
    document_style = Map.get(template_doc, "documentStyle") || %{}

    case Map.fetch(section_style, "flipPageOrientation") do
      {:ok, flip} when is_boolean(flip) -> flip
      _ -> Map.get(document_style, "flipPageOrientation", false)
    end
  end

  # width > height; no pageSize (or a pageSize missing a dimension) is never
  # landscape.
  defp landscape_shaped?(page_size) when is_map(page_size) do
    width = magnitude(Map.get(page_size, "width"))
    height = magnitude(Map.get(page_size, "height"))

    is_number(width) and is_number(height) and width > height
  end

  defp landscape_shaped?(_), do: false

  # A body's first structural element is always the section break that
  # opens its first section.
  defp first_section_style(template_doc) do
    case get_in(template_doc, ["body", "content"]) do
      [%{"sectionBreak" => %{"sectionStyle" => %{} = style}} | _] -> style
      _ -> %{}
    end
  end

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

  Safe to batch with the insert it styles: text style changes never shift
  document character indices, so nothing else in the same batch needs to
  account for these requests' presence. One ordering contract: for the same
  range these must come AFTER `paragraph_style_requests/2`, which resets
  text style — use `paragraph_then_text_style_requests/3`.
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

  @doc """
  Builds `updateParagraphStyle` requests replaying captured paragraph style
  (alignment, line spacing, space above/below, named style type,
  start/first-line indentation — see
  `flatten_template_with_table_markers_and_styles/1`'s `cell_paragraphs` /
  `body_paragraphs`), anchored at `base_index` the same way
  `text_style_requests/2` anchors character runs.

  Every field is always included in the request's `fields` mask — the
  same anti-inheritance guarantee `text_style_fields/1` applies to
  bold/italic. A property the template paragraph doesn't set (captured as
  `nil`) is left out of the payload, which the Docs API reads as "unset":
  it then resolves against the paragraph's named style in the target
  document (the same result as in the template wherever the two documents'
  named styles agree — see `extract_paragraph_style/2`), instead of being
  pinned to a concrete value the template never asked for. Without the
  complete mask, a newly split paragraph in the target document would
  inherit alignment/spacing/named style from whatever paragraph sat at the
  insertion point (e.g. an appended section's plain paragraph picking up
  CENTER alignment from a neighboring heading), not from the source
  template.

  Unlike `text_style_requests/2`, spans are never merged — each paragraph
  gets its own request, since paragraphs are already discrete units (no
  benefit to coalescing, even when two adjacent ones share identical style).
  A span whose `length` is 0 (a paragraph with no textRun at all — doesn't
  happen for a real, non-empty paragraph, since even a blank line carries a
  `"\\n"`-only run) is skipped: with zero characters, it contributes no
  offset and doesn't exist as distinct content in the inserted text either.

  Ranges deliberately use the paragraph's own natural (un-stripped) length,
  even for a table cell's last paragraph whose *text* had its trailing
  newline stripped before insertion (see `cell_fill_requests/4`) — the
  cell's pre-existing bare paragraph supplies that newline structurally
  either way, so the natural length lands the range exactly on it. See
  `cell_paragraph_spans/2`'s doc for the full argument.

  Safe to batch with the insert/fill it styles: like character style
  changes, paragraph style changes never shift document indices. They DO
  reset the text style of the paragraphs they touch (the mask includes
  `namedStyleType`), so for the same range they must come BEFORE
  `text_style_requests/2` — use `paragraph_then_text_style_requests/3`.
  """
  @spec paragraph_style_requests(integer(), [map()]) :: [map()]
  def paragraph_style_requests(base_index, spans) when is_list(spans) do
    spans
    |> Enum.filter(&(&1.length > 0))
    |> Enum.map(fn span ->
      paragraph_style_request(
        base_index + span.start_offset,
        base_index + span.start_offset + span.length,
        span.style
      )
    end)
  end

  defp paragraph_style_request(range_start, range_end, style) do
    %{
      "updateParagraphStyle" => %{
        "range" => %{"startIndex" => range_start, "endIndex" => range_end},
        "paragraphStyle" =>
          reject_unset(%{
            "alignment" => style.alignment,
            "lineSpacing" => style.line_spacing,
            "spaceAbove" => dimension_payload(style.space_above),
            "spaceBelow" => dimension_payload(style.space_below),
            "namedStyleType" => style.named_style_type,
            "indentStart" => dimension_payload(style.indent_start),
            "indentFirstLine" => dimension_payload(style.indent_first_line)
          }),
        "fields" =>
          "alignment,lineSpacing,spaceAbove,spaceBelow,namedStyleType,indentStart,indentFirstLine"
      }
    }
  end

  defp dimension_payload(%{magnitude: magnitude, unit: unit}),
    do: %{"magnitude" => magnitude, "unit" => unit}

  defp dimension_payload(nil), do: nil

  # A property named in the `fields` mask but absent from the payload is how
  # the Docs API spells "unset it" (verified live) — the mask always stays
  # complete, so nothing is ever left to inherit from neighboring content.
  defp reject_unset(paragraph_style),
    do: Map.reject(paragraph_style, fn {_key, value} -> is_nil(value) end)

  @doc """
  Builds `createParagraphBullets` requests replaying captured list
  membership (see `extract_bullet_info/2`'s doc for what "replaying" means
  here — glyph *family*, not exact glyph/format). Contiguous spans (no gap
  in offsets, same source `listId`) are merged into a single request
  spanning the whole run, so consecutive list items land in one target list
  (numbered items continuing count 1, 2, 3, ... instead of each restarting
  at 1) rather than `length(spans)` separate single-paragraph lists.

  Spans with no `bullet` (not a list item) or zero `length` (see
  `paragraph_style_requests/2`) are excluded before grouping.

  Requests are emitted in DESCENDING range order: `createParagraphBullets`
  strips leading tabs from paragraphs in its range, which shifts every
  later index — applying the highest range first means any shift lands
  only below ranges that are already done, the same reasoning as every
  other index-shifting pass in this module.
  """
  @spec paragraph_bullet_requests(integer(), [map()]) :: [map()]
  def paragraph_bullet_requests(base_index, spans) when is_list(spans) do
    spans
    |> Enum.filter(&(&1.length > 0 and not is_nil(&1.bullet)))
    |> group_contiguous_bullet_spans()
    |> Enum.map(fn {first, last} ->
      %{
        "createParagraphBullets" => %{
          "range" => %{
            "startIndex" => base_index + first.start_offset,
            "endIndex" => base_index + last.start_offset + last.length
          },
          "bulletPreset" => first.bullet.preset
        }
      }
    end)
    |> Enum.reverse()
  end

  # List membership lives on `paragraph.bullet`, which updateParagraphStyle
  # cannot touch — only deleteParagraphBullets clears it. When the target
  # document's last paragraph is a list item, the paragraph split the section
  # break makes (see append_template/3) leaves the fresh first paragraph a list
  # item too, so the appended section's heading would render with a stray
  # bullet glyph. One delete over the whole inserted body clears anything
  # inherited; the createParagraphBullets requests that follow re-create the
  # section's own captured lists. Deleting a bullet removes no text (nesting
  # is preserved via indent, a paragraph-style change), so indices are
  # unaffected. Skipped for an empty body — Google rejects an empty range.
  defp clear_inherited_bullets(_content_start, ""), do: []

  defp clear_inherited_bullets(content_start, text) do
    [
      %{
        "deleteParagraphBullets" => %{
          "range" => %{
            "startIndex" => content_start,
            "endIndex" => content_start + utf16_units(text)
          }
        }
      }
    ]
  end

  defp group_contiguous_bullet_spans(spans) do
    spans
    |> Enum.reduce([], &extend_or_start_bullet_group/2)
    |> Enum.reverse()
  end

  defp extend_or_start_bullet_group(span, [{first, prev} | rest] = acc) do
    if contiguous_same_list?(prev, span) do
      [{first, span} | rest]
    else
      [{span, span} | acc]
    end
  end

  defp extend_or_start_bullet_group(span, []), do: [{span, span}]

  defp contiguous_same_list?(prev, span) do
    prev.start_offset + prev.length == span.start_offset and
      prev.bullet.list_id == span.bullet.list_id
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
  # followed by its own style requests — paragraph, then character, see
  # `paragraph_then_text_style_requests/3` (safe within the same descending
  # pass — style requests don't shift indices).
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

        cell_paragraphs_list =
          Map.get(table_info, :cell_paragraphs, List.duplicate([], length(cell_texts)))

        cells = extract_table_cells(table_el)

        Enum.zip([cells, cell_texts, cell_runs_list, cell_paragraphs_list])
      end)
      |> Enum.sort_by(fn {%{insert_index: idx}, _text, _runs, _paragraphs} -> idx end, :desc)
      |> Enum.flat_map(fn {%{insert_index: idx}, text, runs, paragraphs} ->
        cell_fill_requests(idx, text, runs, paragraphs)
      end)

    column_width_requests ++ cell_fill_requests_list
  end

  # An empty cell inserts no text, but its captured paragraph style must
  # still replay against the cell's pre-existing bare paragraph — a blank
  # but CENTER/END-aligned cell (spacer column, empty signature cell) would
  # otherwise silently revert to START. Padded cells from a ragged source
  # row carry no captured paragraphs, so they emit nothing here.
  defp cell_fill_requests(idx, "", _runs, paragraphs),
    do: paragraph_style_requests(idx, paragraphs)

  defp cell_fill_requests(idx, text, runs, paragraphs) do
    [text_insert_request(idx, text) | paragraph_then_text_style_requests(idx, paragraphs, runs)] ++
      paragraph_bullet_requests(idx, paragraphs)
  end

  # The one place the two style kinds are put in order, for body text and
  # table cells alike: paragraph style first. An `updateParagraphStyle` whose
  # mask includes `namedStyleType` resets the text style of the paragraphs
  # it touches, so character style sent before it is wiped (see
  # `append_template/3`'s doc). Neither kind shifts indices, so both share
  # the same `base_index`.
  @doc false
  @spec paragraph_then_text_style_requests(integer(), [map()], [map()]) :: [map()]
  def paragraph_then_text_style_requests(base_index, paragraphs, runs),
    do: paragraph_style_requests(base_index, paragraphs) ++ text_style_requests(base_index, runs)

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
  another. Section ranges are also recalculated (`shift_ranges/2`) by the net
  UTF-16 delta of every *body* text replacement, so the image phase matches
  markers against boundaries that reflect the edited document rather than the
  original one.

  Headers and footers get their own pass. A composed document only ever
  inherits the headers/footers of its first section (`copy_document/2` copies
  them; `append_template/3` appends body content only), so a `{{key}}` found
  there is resolved against whichever section has the lowest `position` —
  never by range containment, since header/footer content has no body index
  at all. Each header/footer segment has its own Docs index space (a Docs
  `segmentId`), independent of the body's, so those replacements are excluded
  from `shift_ranges/2` and sent as their own `segmentId`-scoped requests.
  """
  @spec substitute_all_sections(String.t(), [map()], %{
          non_neg_integer() => {integer(), integer()}
        }) ::
          :ok | {:error, term()}
  def substitute_all_sections(doc_id, sections, ranges) do
    # Phase 1: text substitution — one fetch, one batchUpdate in reverse-index order.
    with {:ok, %{body: doc}} <- get_document(doc_id),
         {:ok, body_replacements, header_footer_replacements} <-
           collect_text_replacements(doc, sections, ranges),
         {:ok, _} <-
           apply_text_replacements(doc_id, body_replacements, header_footer_replacements),
         # Phase 2: image substitution — re-fetch so indices are current after text edits.
         {:ok, %{body: doc2}} <- get_document(doc_id) do
      # Text substitution changed the document's length, so every index after an
      # edit has moved. The image phase matches `{{ images: name }}` markers by
      # index against each section's range — passing the pre-substitution ranges
      # silently drops markers that drifted outside their (stale) section, which
      # is exactly what happens to the last sections of a multi-section compose.
      # Header/footer replacements live in their own index space and never
      # shift body section boundaries.
      substitute_all_images(doc_id, doc2, sections, shift_ranges(ranges, body_replacements))
    end
  end

  # Google Docs silently strips these code points from any text sent through
  # `insertText` — control characters (including CR, U+000D) and the Unicode
  # Basic Multilingual Plane Private Use Area — per the "text" field docs on
  # InsertTextRequest:
  # https://developers.google.com/docs/api/reference/rest/v1/documents/request#InsertTextRequest
  #
  # A `:multiline` variable rendered from a `<textarea>` routinely contains
  # CRLF line endings, so counting the raw value in UTF-16 units overstates
  # the delta Google actually applies and drags every later section boundary
  # rightward (see shift_ranges/2). Stripping here, once, and reusing this
  # exact string both for the `insertText` request (apply_text_replacements/2)
  # and for the delta arithmetic (shift_ranges/2) makes the two agree by
  # construction — there is no second copy of the value that could drift out
  # of sync with what Google actually inserts.
  @docs_stripped_chars ~r/[\x{0000}-\x{0008}\x{000C}-\x{001F}\x{E000}-\x{F8FF}]/u

  defp sanitize_insert_text(text), do: Regex.replace(@docs_stripped_chars, text, "")

  # Body placeholder matches paired with their replacement values, as
  # `{key, start_index, end_index, value}`, sorted descending by start index so
  # applying them in order never shifts a not-yet-applied match. Header/footer
  # matches carry an extra `segment_id` (the Docs `segmentId` their index space
  # belongs to) and are returned separately, since they must never feed
  # `shift_ranges/2` — body deltas don't apply to their independent index space.
  defp collect_text_replacements(doc, sections, ranges) do
    all_keys = sections |> Enum.flat_map(&Map.keys(&1.variable_values)) |> Enum.uniq()

    # A composed document only ever inherits the first section's headers/footers
    # (see substitute_all_sections/3's doc), so that's the only section whose
    # variable_values can resolve a header/footer placeholder.
    header_footer_section = Enum.min_by(sections, & &1.position)

    body_replacements =
      doc
      |> body_text_runs()
      |> Enum.flat_map(&find_text_var_ranges(&1, all_keys))
      |> Enum.flat_map(fn %{key: key, start_index: s, end_index: e} = match ->
        case section_for_match(sections, ranges, match) do
          nil -> []
          section -> [{key, s, e, resolved_value(section, key)}]
        end
      end)
      |> Enum.sort_by(fn {_, s, _, _} -> s end, :desc)

    header_footer_replacements =
      doc
      |> header_footer_text_runs()
      |> Enum.flat_map(fn {segment_id, run} ->
        run
        |> find_text_var_ranges(all_keys)
        |> Enum.flat_map(&header_footer_replacement(&1, header_footer_section, segment_id))
      end)
      |> Enum.sort_by(fn {_, s, _, _, _} -> s end, :desc)

    {:ok, body_replacements, header_footer_replacements}
  end

  defp header_footer_replacement(%{key: key, start_index: s, end_index: e}, section, segment_id) do
    if Map.has_key?(section.variable_values, key) do
      [{key, s, e, resolved_value(section, key), segment_id}]
    else
      []
    end
  end

  defp resolved_value(section, key),
    do: section.variable_values[key] |> to_string() |> sanitize_insert_text()

  defp apply_text_replacements(doc_id, body_replacements, header_footer_replacements) do
    requests =
      Enum.flat_map(body_replacements, fn {_, s, e, value} ->
        text_replacement_requests(s, e, value, nil)
      end) ++
        Enum.flat_map(header_footer_replacements, fn {_, s, e, value, segment_id} ->
          text_replacement_requests(s, e, value, segment_id)
        end)

    maybe_batch(&batch_update/2, doc_id, requests)
  end

  # `segment_id` is the Docs `segmentId` a header/footer's content lives under;
  # `nil` for the body, which omits the field entirely rather than sending it
  # as `nil` — matching what a body-only substitution has always sent.
  defp text_replacement_requests(s, e, value, segment_id) do
    range = maybe_put_segment(%{startIndex: s, endIndex: e}, segment_id)
    location = maybe_put_segment(%{index: s}, segment_id)
    delete = %{deleteContentRange: %{range: range}}

    # Google rejects insertText with empty text, and batchUpdate is atomic —
    # one empty value would void every substitution in the batch. A blank
    # variable clears its placeholder, mirroring the image path's behavior.
    case value do
      "" -> [delete]
      _ -> [delete, %{insertText: %{location: location, text: value}}]
    end
  end

  defp maybe_put_segment(map, nil), do: map
  defp maybe_put_segment(map, segment_id), do: Map.put(map, :segmentId, segment_id)

  @doc false
  # Moves each section boundary by the net length change of every replacement
  # that starts before it. A replacement is `{key, start_index, end_index,
  # value}`; its delta is `length(value) - (end_index - start_index)` in UTF-16
  # code units — the unit Google Docs indices are expressed in.
  #
  # Boundaries are exclusive-end, so a replacement starting exactly at a
  # boundary belongs to the following section and must not move that boundary's
  # start; `<` (not `<=`) is deliberate on both edges.
  @spec shift_ranges(%{non_neg_integer() => {integer(), integer()}}, [
          {String.t(), integer(), integer(), String.t()}
        ]) :: %{non_neg_integer() => {integer(), integer()}}
  def shift_ranges(ranges, []), do: ranges

  def shift_ranges(ranges, replacements) do
    deltas =
      Enum.map(replacements, fn {_key, s, e, value} ->
        {s, utf16_units(value) - (e - s)}
      end)

    Map.new(ranges, fn {position, {range_start, range_end}} ->
      {position,
       {range_start + shift_at(deltas, range_start), range_end + shift_at(deltas, range_end)}}
    end)
  end

  defp shift_at(deltas, index) do
    deltas
    |> Enum.filter(fn {s, _delta} -> s < index end)
    |> Enum.map(fn {_s, delta} -> delta end)
    |> Enum.sum()
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
  #
  # Every slot's width comes from the `section_boxes/1` box of the DOCS
  # SECTION it physically sits in (falling back to `content_width_pt(doc2)`
  # when no box matches) rather than the whole document's `content_width_pt`
  # — this is what makes an image_list slot render at the landscape section's
  # own width instead of the document's (portrait) one, with no config flag.
  defp apply_image_fills(doc_id, doc2, all_image_fills) do
    fills_map = Map.new(all_image_fills, fn {name, fill, _} -> {name, fill} end)
    range_by_name = Map.new(all_image_fills, fn {name, _, range} -> {name, range} end)
    boxes = section_boxes(doc2)

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

    fit_page_names = resolve_fit_page_names(filtered_ranges, fills_map, doc2, boxes)

    # Phase 1 batch: inline slot deletes+inserts + table slot delete+insertTable.
    # Sort all requests descending by start_index so earlier inserts don't shift later ones.
    phase1_requests =
      boxed_image_batch_requests(
        table_ranges ++ inline_ranges,
        fills_map,
        doc2,
        boxes,
        fit_page_names
      )

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
          doc2,
          boxes,
          pre_existing_table_starts
        )
      end
    end
  end

  # Like `build_image_batch_requests/3`, but resolves each slot's width from
  # the `section_boxes/1` box it sits in (see `apply_image_fills/3`'s doc)
  # and, for the slots `resolve_fit_page_names/4` cleared for `fit: "page"`,
  # scales the image to fill the section's remaining page instead.
  defp boxed_image_batch_requests(ranges, fills_map, doc2, boxes, fit_page_names) do
    ranges
    |> Enum.sort_by(& &1.start_index, :desc)
    |> Enum.flat_map(fn %{name: name, start_index: s, end_index: e} ->
      fill = Map.fetch!(fills_map, name)
      delete = %{deleteContentRange: %{range: %{startIndex: s, endIndex: e}}}
      box = box_for_index(boxes, s)
      content_width_pt = (box && box.width_pt) || content_width_pt(doc2)

      inserts =
        case fill.kind do
          :image ->
            single_image_inserts(fill, s)

          :image_list ->
            list_image_inserts_boxed(fill, s, content_width_pt, box, doc2, name, fit_page_names)
        end

      [delete | inserts]
    end)
  end

  defp list_image_inserts_boxed(%{media: []}, _index, _cw, _box, _doc2, _name, _fit_names),
    do: []

  defp list_image_inserts_boxed(fill, index, content_width_pt, box, doc2, name, fit_page_names) do
    cols = Map.get(fill, :columns, 1)

    cond do
      cols >= 2 ->
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

      box && MapSet.member?(fit_page_names, name) ->
        paragraphs_reserve_pt = paragraphs_reserve_before_slot(doc2, box, index)
        page_fit_image_list_inserts(fill, index, box, paragraphs_reserve_pt)

      true ->
        w_pt = image_width_for_columns(content_width_pt, 1)
        inline_image_inserts_pt(fill, index, w_pt)
    end
  end

  # Host-tunable RESIDUAL safety margin subtracted from a `fit: "page"`
  # image's available height — on EVERY image of the slot, not just the
  # section's first. Configure via `config :phoenix_kit_document_creator,
  # :page_fit_safety_pt, N` (see the `Configuration` section of this
  # module's `@moduledoc` — the top/bottom of the available area now comes
  # from `section_boxes/1`'s `body_top_pt`/`body_bottom_pt`, so this only
  # needs to cover what that estimate can't see).
  @spec page_fit_safety_pt() :: float()
  def page_fit_safety_pt do
    Application.get_env(:phoenix_kit_document_creator, :page_fit_safety_pt, 8.0) * 1.0
  end

  # Same last-first / separator dance as `inline_image_inserts_pt/3`, but
  # sizes each image to fill the section's remaining page (`fit: "page"`).
  # Available height is `body_bottom_pt - start - trailing_line -
  # page_fit_safety_pt/0` (see the moduledoc for how `body_top_pt` /
  # `body_bottom_pt` are derived from the section's header/footer content).
  # `trailing_line_pt` (one line of the section's terminal paragraph) is
  # applied to every image, not just the section's last, for simplicity.
  # The media item that ends up FIRST in the rendered document (the last one
  # processed here, since inserts land ahead of what's already there — see
  # `inline_image_inserts_pt/3`'s sibling logic) starts at
  # `max(body_top_pt, margin_top + paragraphs_reserve_pt)` — the estimated
  # height of the section's own text ahead of it, when that pushes further
  # down than the header already does; text is not pushed down by the
  # header the way an image is (see `paragraphs_reserve_before_slot/3`'s
  # doc), so the two reserves are combined with `max`, not summed. Every
  # image after it starts a fresh page (the previous one filled its own), so
  # it simply starts at `body_top_pt`.
  defp page_fit_image_list_inserts(fill, index, box, paragraphs_reserve_pt) do
    %{media: media, separator: sep} = fill
    reversed = Enum.reverse(media)
    last_idx = length(reversed) - 1
    safety_pt = page_fit_safety_pt()

    reversed
    |> Enum.with_index()
    |> Enum.flat_map(fn {m, i} ->
      start_pt =
        if i == last_idx do
          max(box.body_top_pt, box.margin_top + paragraphs_reserve_pt)
        else
          box.body_top_pt
        end

      avail_h = max(box.body_bottom_pt - start_pt - @page_fit_trailing_line_pt - safety_pt, 0.0)
      img = page_fit_insert(m, index, box.width_pt, avail_h)
      if i < last_idx, do: [img, separator_request(sep, index)], else: [img]
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp page_fit_insert(media, index, box_w, avail_h) when is_map(media) do
    uri = Map.get(media, :uri) || Map.get(media, "uri")
    w_px = Map.get(media, :width_px) || Map.get(media, "width_px")
    h_px = Map.get(media, :height_px) || Map.get(media, "height_px")

    {width_pt, height_pt} = page_fit_dimensions(box_w, avail_h, w_px, h_px)

    %{
      insertInlineImage: %{
        location: %{index: index},
        uri: uri,
        objectSize: %{
          width: %{magnitude: width_pt * 1.0, unit: "PT"},
          height: %{magnitude: height_pt * 1.0, unit: "PT"}
        }
      }
    }
  end

  # scale = min(box_w / w_px, avail_h / h_px) — the image is scaled down to
  # fit whichever of width/height runs out first, aspect ratio preserved.
  defp page_fit_dimensions(box_w, avail_h, w_px, h_px)
       when is_number(w_px) and w_px > 0 and is_number(h_px) and h_px > 0 and avail_h > 0 do
    scale = min(box_w / w_px, avail_h / h_px)
    {w_px * scale, h_px * scale}
  end

  # No usable source dimensions, or the reserve ate the whole box (avail_h
  # <= 0) — fall back to today's width-based scaling (`scale_height/3`)
  # rather than emit a non-positive size the API would reject.
  defp page_fit_dimensions(box_w, _avail_h, w_px, h_px) do
    scaled_h = scale_height(box_w, w_px, h_px) || box_w
    {box_w, scaled_h}
  end

  # Sum of estimated heights of every paragraph in `box`'s section that
  # fully precedes `slot_start_index` (a paragraph containing the slot
  # itself has `endIndex > slot_start_index` and is excluded). Combined
  # with `page_fit_safety_pt/0` by the caller — see
  # `page_fit_image_list_inserts/4`'s doc. See
  # `estimate_paragraph_height_pt/1` for the per-paragraph estimate.
  defp paragraphs_reserve_before_slot(doc, box, slot_start_index) do
    (get_in(doc, ["body", "content"]) || [])
    |> Enum.filter(fn el ->
      Map.has_key?(el, "paragraph") and
        Map.get(el, "startIndex", 0) >= box.start_index and
        Map.get(el, "endIndex", 0) <= slot_start_index
    end)
    |> Enum.map(&estimate_paragraph_height_pt/1)
    |> Enum.sum()
  end

  # (lineCount × fontSize × lineSpacing/100 × @font_leading) + spaceAbove +
  # spaceBelow, each falling back to Docs' own normal-text defaults (11pt /
  # 115%) when absent — including an empty paragraph, which still occupies
  # one line at the default size.
  #
  # `@font_leading` (1.22): Docs lays out a line taller than the naive
  # fontSize × lineSpacing/100 product — measured live (2026-09-23, the same
  # composite-preview document as the header/footer estimator's fixture) at
  # a body-text line pitch of ~14.55pt for Arial 11pt/115% (12.65 × ~1.15)
  # and ~13.35pt for the house footer's Calibri 9.5pt/115% (10.925 × ~1.22)
  # — different real multipliers per font, but a single constant is what
  # `section_boxes/1`'s reserve/extent estimators can compute without a live
  # render. `1.22` is the larger of the two: it overestimates Arial's true
  # line height by ~6%, the safe direction (a slightly bigger reserve/extent
  # costs a few points of image height, not an overflow).
  #
  # `paragraph_line_count/1` adds one line per `\u000B` "soft line break"
  # inside the paragraph's own text (seen live in the house footer's
  # details table cells, e.g. "Reg. kood 10827447\u000BKMKR nr ..." on one
  # visual line's worth of Docs paragraph but two rendered lines) — a plain
  # `\n` paragraph break is already its own structural element and isn't
  # counted here.
  defp estimate_paragraph_height_pt(%{"paragraph" => paragraph}) do
    style = Map.get(paragraph, "paragraphStyle") || %{}
    line_spacing = numeric_or_nil(Map.get(style, "lineSpacing")) || @default_line_spacing_pct
    space_above = magnitude(Map.get(style, "spaceAbove")) || 0.0
    space_below = magnitude(Map.get(style, "spaceBelow")) || 0.0
    font_size = paragraph_font_size_pt(paragraph)
    lines = paragraph_line_count(paragraph)

    lines * font_size * (line_spacing / 100.0) * @font_leading + space_above + space_below
  end

  defp estimate_paragraph_height_pt(_), do: 0.0

  defp paragraph_font_size_pt(paragraph) do
    paragraph
    |> Map.get("elements", [])
    |> Enum.find_value(&get_in(&1, ["textRun", "textStyle", "fontSize", "magnitude"]))
    |> case do
      fs when is_number(fs) -> fs * 1.0
      _ -> @default_paragraph_font_size_pt
    end
  end

  defp paragraph_line_count(paragraph) do
    soft_breaks =
      paragraph
      |> Map.get("elements", [])
      |> Enum.map_join(&(get_in(&1, ["textRun", "content"]) || ""))
      |> String.split("\u000B")
      |> length()
      |> Kernel.-(1)

    1 + soft_breaks
  end

  # Determines which `image_list`, `fit: "page"` slots actually get the
  # page-fit treatment (scope v1 — see `apply_image_fills/3`'s callers and
  # the spec): columns must be 1, the slot must not sit inside a table cell,
  # and at most one per section — the earliest (lowest start_index) wins.
  # Every slot that asked for `fit: "page"` but doesn't qualify falls back
  # to `fit: "width"` with a logged reason.
  defp resolve_fit_page_names(ranges, fills_map, doc2, boxes) do
    table_spans =
      doc2
      |> collect_tables()
      |> Enum.map(&{Map.get(&1, "startIndex", 0), Map.get(&1, "endIndex", 0)})

    ranges
    |> Enum.filter(&wants_fit_page?(&1, fills_map))
    |> Enum.sort_by(& &1.start_index)
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn range, acc ->
      accept_or_reject_fit_page(range, fills_map, table_spans, boxes, acc)
    end)
    |> elem(0)
  end

  defp wants_fit_page?(%{name: name}, fills_map) do
    fill = Map.fetch!(fills_map, name)
    fill.kind == :image_list and Map.get(fill, :fit, :width) == :page
  end

  defp accept_or_reject_fit_page(
         %{name: name, start_index: s},
         fills_map,
         table_spans,
         boxes,
         {names, used}
       ) do
    fill = Map.fetch!(fills_map, name)
    box_key = boxes |> box_for_index(s) |> then(&(&1 && &1.start_index))

    case fit_page_rejection_reason(fill, s, table_spans, box_key, used) do
      nil ->
        {MapSet.put(names, name), if(box_key, do: MapSet.put(used, box_key), else: used)}

      reason ->
        Logger.warning(
          "fit=page ignored for image slot #{inspect(name)}: #{reason}; falling back to fit=width"
        )

        {names, used}
    end
  end

  defp fit_page_rejection_reason(fill, s, table_spans, box_key, used) do
    cond do
      Map.get(fill, :columns, 1) != 1 ->
        "columns >= 2 is out of scope"

      Enum.any?(table_spans, fn {ts, te} -> s >= ts and s < te end) ->
        "the slot sits inside a table cell"

      box_key && MapSet.member?(used, box_key) ->
        "its section already has a fit=page slot"

      true ->
        nil
    end
  end

  # Phase 2: re-fetch the doc after table creation, locate the newly inserted
  # tables via `match_new_tables/3` (order-based, drift-proof — see its docs),
  # and fill their cells.
  defp do_fill_table_cells(
         doc_id,
         table_ranges,
         fills_map,
         doc2,
         boxes,
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
          fill_matched_tables(doc_id, table_slots_asc, new_tables, fills_map, doc2, boxes)
      end
    end
  end

  # Build and run the Phase 2 batch: one insertInlineImage per cell across all
  # matched tables, paired with their slots in document order. Each table's
  # width comes from its own section's box, same as the inline path.
  defp fill_matched_tables(doc_id, table_slots_asc, new_tables, fills_map, doc2, boxes) do
    phase2_requests =
      table_slots_asc
      |> Enum.zip(new_tables)
      |> Enum.flat_map(fn {%{name: name, start_index: s}, table_el} ->
        fill = Map.fetch!(fills_map, name)
        cols = Map.get(fill, :columns, 1)
        box = box_for_index(boxes, s)
        content_width_pt = (box && box.width_pt) || content_width_pt(doc2)
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

  # Walk every header and footer segment, returning each textRun element
  # paired with the Docs `segmentId` (the map key under "headers"/"footers")
  # its indices belong to — a header/footer's own index space, independent of
  # the body's and of every other segment's.
  defp header_footer_text_runs(doc) do
    segment_text_runs(Map.get(doc, "headers", %{})) ++
      segment_text_runs(Map.get(doc, "footers", %{}))
  end

  defp segment_text_runs(segments) do
    Enum.flat_map(segments, fn {segment_id, segment} ->
      segment
      |> Map.get("content", [])
      |> Enum.flat_map(&walk_block/1)
      |> Enum.filter(&match?(%{"textRun" => _, "startIndex" => _}, &1))
      |> Enum.map(&{segment_id, &1})
    end)
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
        fit: normalize_fit_atom(Map.get(params, "fit")),
        media: media_items
      }

      {name, fill}
    end)
  end

  defp normalize_fit_atom("page"), do: :page
  defp normalize_fit_atom(:page), do: :page
  defp normalize_fit_atom(_), do: :width

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

  @drive_permission_403_reasons ~w(
    forbidden
    insufficientFilePermissions
    insufficientPermissions
    appNotAuthorizedToFile
    domainPolicy
    teamDriveMembershipRequired
  )

  @drive_rate_limit_403_reasons ~w(
    userRateLimitExceeded
    rateLimitExceeded
    dailyLimitExceeded
    quotaExceeded
    sharingRateLimitExceeded
  )

  # Classifies a Drive API 403 response body by its `error.errors[].reason`
  # (falling back to `error.reason` for the single-error shape some Drive
  # endpoints use) into a permission failure vs. a rate/quota limit vs.
  # the caller's own generic reason. Shared by any caller that needs to
  # tell "the connected account can't read this file" apart from "try
  # again later" — hence `fallback`: an unrecognized 403 reports the
  # operation that actually failed instead of borrowing another
  # endpoint's message.
  defp classify_403(body, fallback) do
    case drive_403_reason(body) do
      reason when reason in @drive_permission_403_reasons -> :drive_forbidden
      reason when reason in @drive_rate_limit_403_reasons -> :drive_rate_limited
      # Export-only, but harmless elsewhere: no other endpoint emits it.
      "exportSizeLimitExceeded" -> :drive_export_too_large
      _other -> fallback
    end
  end

  defp drive_403_reason(%{"error" => %{"errors" => [%{"reason" => reason} | _]}}), do: reason
  defp drive_403_reason(%{"error" => %{"reason" => reason}}), do: reason
  defp drive_403_reason(_body), do: nil

  defp truncate_inspect(value, limit) do
    inspected = inspect(value, limit: :infinity, printable_limit: limit)

    if String.length(inspected) > limit do
      String.slice(inspected, 0, limit) <> "…(truncated)"
    else
      inspected
    end
  end
end
