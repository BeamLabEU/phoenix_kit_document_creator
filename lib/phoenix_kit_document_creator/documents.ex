defmodule PhoenixKitDocumentCreator.Documents do
  @moduledoc """
  Context module for managing templates and documents via Google Drive.

  Google Drive is the single source of truth. Templates live in a
  `/templates` folder and documents in a `/documents` folder in the
  connected Google account's Drive. No local database records are used
  for document/template storage.
  """

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # ===========================================================================
  # Listing
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
        GoogleDocsClient.create_document(name, parent: id)

      _ ->
        {:error, :templates_folder_not_found}
    end
  end

  @doc "Create a blank document in the documents folder. Returns `{:ok, %{doc_id, name, url}}`."
  def create_document(name \\ "Untitled Document") do
    case get_folder_ids() do
      %{documents_folder_id: id} when is_binary(id) ->
        GoogleDocsClient.create_document(name, parent: id)

      _ ->
        {:error, :documents_folder_not_found}
    end
  end

  @doc """
  Create a document from a template by copying and filling variables.

  1. Copies the template Google Doc to the documents folder
  2. Replaces all `{{variable}}` placeholders with values
  3. Returns `{:ok, %{doc_id, url}}`
  """
  def create_document_from_template(template_file_id, variable_values, opts \\ []) do
    doc_name = Keyword.get(opts, :name, "New Document")

    case get_folder_ids() do
      %{documents_folder_id: folder_id} when is_binary(folder_id) ->
        with {:ok, new_doc_id} <-
               GoogleDocsClient.copy_file(template_file_id, doc_name, parent: folder_id),
             {:ok, _} <- GoogleDocsClient.replace_all_text(new_doc_id, variable_values) do
          {:ok, %{doc_id: new_doc_id, url: GoogleDocsClient.get_edit_url(new_doc_id)}}
        end

      _ ->
        {:error, :documents_folder_not_found}
    end
  end

  # ===========================================================================
  # Variables
  # ===========================================================================

  @doc "Detect `{{ variables }}` in a Google Doc's text content."
  def detect_variables(file_id) when is_binary(file_id) do
    case GoogleDocsClient.get_document_text(file_id) do
      {:ok, text} ->
        vars = PhoenixKitDocumentCreator.Variable.extract_from_html(text)
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

  @doc "Fetch thumbnails for a list of Drive files. Returns `%{file_id => data_uri}`."
  def fetch_thumbnails(files) when is_list(files) do
    files
    |> Enum.reduce(%{}, fn file, acc ->
      file_id = file["id"]

      case GoogleDocsClient.fetch_thumbnail(file_id) do
        {:ok, data_uri} -> Map.put(acc, file_id, data_uri)
        _ -> acc
      end
    end)
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
