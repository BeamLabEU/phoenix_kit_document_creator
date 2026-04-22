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

  The walker uses Drive's `in parents` OR-batching to list files for many
  folders in a single request (chunked to stay under Drive's query-length
  limit), and streams result pages via `nextPageToken` — the old
  `pageSize: 100` listing silently dropped data past the first page.
  """

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

  defp bfs_folders(root_id, root_path, max_depth) do
    initial = %{root_id => %{name: "", path: root_path}}
    bfs_step([{root_id, root_path, 0}], initial, max_depth)
  end

  defp bfs_step([], acc, _max_depth), do: {:ok, acc}

  defp bfs_step([{_fid, _path, depth} | rest], acc, max_depth) when depth >= max_depth do
    bfs_step(rest, acc, max_depth)
  end

  defp bfs_step([{fid, path, depth} | rest], acc, max_depth) do
    case list_folders(fid) do
      {:ok, subs} ->
        {new_acc, new_queue} =
          Enum.reduce(subs, {acc, rest}, fn %{"id" => sid, "name" => sname}, {a, q} ->
            spath = join_path(path, sname)
            {Map.put(a, sid, %{name: sname, path: spath}), q ++ [{sid, spath, depth + 1}]}
          end)

        bfs_step(new_queue, new_acc, max_depth)

      {:error, _} = err ->
        err
    end
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
        {:error, "List files failed: #{inspect(body)}"}

      {:error, _} = err ->
        err
    end
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
  defp join_path(nil, name), do: name
  defp join_path(path, name), do: "#{path}/#{name}"
end
