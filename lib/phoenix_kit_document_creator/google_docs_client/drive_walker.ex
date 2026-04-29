defmodule PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker do
  @moduledoc """
  Paginated + recursive Google Drive traversal.

  Canonical primitive for listing files and folders. The parent
  `PhoenixKitDocumentCreator.GoogleDocsClient` delegates `list_folder_files/1`
  and `list_subfolders/1` here so that pagination logic lives in exactly one
  place.

  The core entry point is `walk_tree/2`, which performs a BFS over a folder
  tree and returns:

    * every descendant folder indexed by ID (with its name and human-readable
      path, relative to the root caller supplied), and
    * every Google Doc found in any of those folders, annotated with the
      `folder_id` that contains it and the `path` of that folder.

  The walker uses Drive's `in parents` OR-batching for **both** folder
  discovery and file listing — one batched request per BFS level instead
  of one request per folder, chunked at 40 parent IDs per query to stay
  under Drive's query-length limit. All pages are streamed via
  `nextPageToken` (the old `pageSize: 100` listing silently dropped data
  past the first page). Folder ownership is resolved from each returned
  folder's `parents` field.
  """

  require Logger

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  @drive_base "https://www.googleapis.com/drive/v3"
  @default_max_depth 20
  # Folders per batched `a in parents or b in parents …` query. 40 folder IDs
  # at ~50 chars each keeps `q` well below Drive's practical GET limit.
  @chunk_size 40
  # Drive caps list pageSize at 1000; using the max reduces round trips.
  @page_size 1000

  @type folder_entry :: %{name: String.t(), path: String.t()}
  @type folder_index :: %{optional(String.t()) => folder_entry()}

  @doc """
  List Google Docs directly in a folder (non-recursive), fully paginated.

  Each file map has at minimum `"id"`, `"name"`, `"modifiedTime"`,
  `"thumbnailLink"`, and `"parents"`.
  """
  @spec list_files(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_files(folder_id) when is_binary(folder_id) and folder_id != "" do
    q =
      "'#{escape(folder_id)}' in parents and " <>
        "mimeType = 'application/vnd.google-apps.document' and trashed = false"

    paginate(q, "files(id,name,modifiedTime,thumbnailLink,parents)")
  end

  def list_files(_), do: {:ok, []}

  @doc """
  List subfolders of a folder (non-recursive), fully paginated.
  Each entry has `"id"` and `"name"`. Results are ordered alphabetically
  by name to preserve the folder browser's existing UX.
  """
  @spec list_folders(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_folders(folder_id) when is_binary(folder_id) and folder_id != "" do
    q =
      "mimeType = 'application/vnd.google-apps.folder' and " <>
        "'#{escape(folder_id)}' in parents and trashed = false"

    paginate(q, "files(id,name)", order_by: "name")
  end

  def list_folders(_), do: {:ok, []}

  @doc """
  Walk a folder tree starting at `root_folder_id`.

  ## Options

    * `:root_path` (string, default `""`) — human-readable path representing
      the root. Descendants get paths computed as `root_path/sub/subsub`.
    * `:max_depth` (int, default `20`) — defensive cap against cycles or
      excessively deep structures. The root is depth 0; children of the root
      are depth 1.

  ## Return value

      {:ok, %{
        folders: %{folder_id => %{name: name, path: path}, ...},
        files:   [%{"id" => ..., "name" => ..., "folder_id" => parent_id,
                    "path" => folder_path, ...}, ...]
      }}

  The returned `folders` index always includes the root folder itself
  (with the `:root_path` you supplied as its path).
  """
  @spec walk_tree(String.t(), keyword()) ::
          {:ok, %{folders: folder_index(), files: [map()]}} | {:error, term()}
  def walk_tree(root_folder_id, opts \\ []) when is_binary(root_folder_id) do
    root_path = Keyword.get(opts, :root_path, "")
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)

    with {:ok, folder_index} <- bfs_folders(root_folder_id, root_path, max_depth),
         {:ok, raw_files} <- list_files_in_folders(Map.keys(folder_index)) do
      files = Enum.map(raw_files, &annotate_file(&1, folder_index))
      {:ok, %{folders: folder_index, files: files}}
    end
  end

  # ---- Folder BFS ---------------------------------------------------------

  # Level-by-level BFS: at each level, issue a single batched
  # `mimeType = 'folder' and (a in parents or b in parents …)` query
  # (chunked at @chunk_size) instead of one request per folder. Folder
  # ownership is resolved from each returned folder's `parents` field by
  # matching against the current level's parent_lookup.
  defp bfs_folders(root_id, root_path, max_depth) do
    initial = %{root_id => %{name: "", path: root_path}}
    bfs_level([{root_id, root_path}], initial, 1, max_depth)
  end

  # `depth` is the depth of the level about to be fetched (root's children = 1).
  # Stopping at `depth > max_depth` mirrors the prior per-folder walker: the
  # deepest folders recorded in the index are at `max_depth`; their children
  # are not enumerated.
  defp bfs_level(_parents, acc, depth, max_depth) when depth > max_depth, do: {:ok, acc}
  defp bfs_level([], acc, _depth, _max_depth), do: {:ok, acc}

  defp bfs_level(parents, acc, depth, max_depth) do
    parent_lookup = Map.new(parents)

    case list_subfolders_of(Map.keys(parent_lookup)) do
      {:ok, raw_folders} ->
        {new_acc, next_level} =
          Enum.reduce(raw_folders, {acc, []}, fn folder, {a, nl} ->
            add_child_folder(folder, parent_lookup, a, nl)
          end)

        bfs_level(next_level, new_acc, depth + 1, max_depth)

      {:error, _} = err ->
        err
    end
  end

  defp add_child_folder(folder, parent_lookup, acc, next_level) do
    %{"id" => sid, "name" => sname} = folder
    parent_ids = folder["parents"] || []

    # A Drive folder can theoretically have multiple parents (shared/starred);
    # the first parent that matches our query-set is the "owning" parent for
    # pathing. If none match (shouldn't happen given our query), skip.
    case Enum.find(parent_ids, &Map.has_key?(parent_lookup, &1)) do
      nil ->
        {acc, next_level}

      parent_id ->
        spath = join_path(parent_lookup[parent_id], sname)

        {
          Map.put(acc, sid, %{name: sname, path: spath}),
          [{sid, spath} | next_level]
        }
    end
  end

  defp list_subfolders_of([]), do: {:ok, []}

  defp list_subfolders_of(folder_ids) do
    folder_ids
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case list_subfolders_chunk(chunk) do
        {:ok, folders} -> {:cont, {:ok, acc ++ folders}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp list_subfolders_chunk(folder_ids) do
    parents_q =
      folder_ids
      |> Enum.map_join(" or ", fn id -> "'#{escape(id)}' in parents" end)

    q =
      "mimeType = 'application/vnd.google-apps.folder' and trashed = false and " <>
        "(#{parents_q})"

    paginate(q, "files(id,name,parents)")
  end

  # ---- Batched file listing ----------------------------------------------

  defp list_files_in_folders([]), do: {:ok, []}

  defp list_files_in_folders(folder_ids) do
    folder_ids
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case list_files_chunk(chunk) do
        {:ok, files} -> {:cont, {:ok, acc ++ files}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp list_files_chunk(folder_ids) do
    parents_q =
      folder_ids
      |> Enum.map_join(" or ", fn id -> "'#{escape(id)}' in parents" end)

    q =
      "mimeType = 'application/vnd.google-apps.document' and trashed = false and " <>
        "(#{parents_q})"

    paginate(q, "files(id,name,modifiedTime,thumbnailLink,parents)")
  end

  defp annotate_file(file, folder_index) do
    parents = file["parents"] || []
    owning_parent = Enum.find(parents, &Map.has_key?(folder_index, &1))

    cond do
      is_binary(owning_parent) ->
        %{path: path} = Map.fetch!(folder_index, owning_parent)

        file
        |> Map.put("folder_id", owning_parent)
        |> Map.put("path", path)

      parents != [] ->
        Map.put(file, "folder_id", List.first(parents))

      true ->
        file
    end
  end

  # ---- HTTP ---------------------------------------------------------------

  defp paginate(q, fields, opts \\ []) do
    do_paginate(q, "nextPageToken,#{fields}", opts, nil, [])
  end

  defp do_paginate(q, fields, opts, page_token, acc) do
    params = build_paginate_params(q, fields, opts, page_token)

    case GoogleDocsClient.authenticated_request(:get, "#{@drive_base}/files", params: params) do
      {:ok, %{status: 200, body: %{"files" => files} = body}} ->
        handle_page(q, fields, opts, acc ++ files, body["nextPageToken"])

      {:ok, %{status: 200}} ->
        {:ok, acc}

      {:ok, %{body: body}} ->
        Logger.warning(
          "[DocumentCreator.DriveWalker] list files failed | body=#{truncate(inspect(body))}"
        )

        {:error, :list_files_failed}

      {:error, _} = err ->
        err
    end
  end

  @log_body_limit 500
  defp truncate(s) when is_binary(s) do
    if String.length(s) > @log_body_limit,
      do: String.slice(s, 0, @log_body_limit) <> "…(truncated)",
      else: s
  end

  defp handle_page(_q, _fields, _opts, acc, nil), do: {:ok, acc}

  defp handle_page(q, fields, opts, acc, token) when is_binary(token) do
    do_paginate(q, fields, opts, token, acc)
  end

  defp build_paginate_params(q, fields, opts, page_token) do
    [q: q, fields: fields, pageSize: @page_size]
    |> maybe_append(:orderBy, Keyword.get(opts, :order_by))
    |> maybe_append(:pageToken, page_token)
  end

  defp maybe_append(params, _key, nil), do: params
  defp maybe_append(params, key, value), do: params ++ [{key, value}]

  # ---- Helpers ------------------------------------------------------------

  defp escape(value), do: value |> to_string() |> String.replace("'", "\\'")

  defp join_path("", name), do: name
  defp join_path(path, name), do: "#{path}/#{name}"
end
