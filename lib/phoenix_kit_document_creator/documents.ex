defmodule PhoenixKitDocumentCreator.Documents do
  @moduledoc """
  Context module for managing templates, documents, and headers/footers.
  """
  import Ecto.Query, warn: false

  alias PhoenixKitDocumentCreator.Schemas.{Document, HeaderFooter, Template}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ═══════════════════════════════════════════════════════════════════
  # Headers & Footers
  # ═══════════════════════════════════════════════════════════════════

  def list_headers_footers do
    HeaderFooter
    |> order_by(asc: :name)
    |> repo().all()
  end

  def get_header_footer(uuid) do
    repo().get(HeaderFooter, uuid)
  end

  def get_header_footer!(uuid) do
    repo().get!(HeaderFooter, uuid)
  end

  def create_header_footer(attrs) do
    %HeaderFooter{}
    |> HeaderFooter.changeset(attrs)
    |> repo().insert()
  end

  def update_header_footer(%HeaderFooter{} = hf, attrs) do
    hf
    |> HeaderFooter.changeset(attrs)
    |> repo().update()
  end

  def delete_header_footer(%HeaderFooter{} = hf) do
    repo().delete(hf)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Templates
  # ═══════════════════════════════════════════════════════════════════

  def list_templates(opts \\ []) do
    query = from(t in Template, order_by: [desc: :updated_at])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [t], t.status == ^status)
      end

    repo().all(query)
  end

  def published_templates do
    list_templates(status: "published")
  end

  def get_template(uuid) do
    repo().get(Template, uuid)
  end

  def get_template!(uuid) do
    repo().get!(Template, uuid)
  end

  def create_template(attrs) do
    %Template{}
    |> Template.changeset(attrs)
    |> repo().insert()
  end

  def update_template(%Template{} = template, attrs) do
    template
    |> Template.changeset(attrs)
    |> repo().update()
  end

  def delete_template(%Template{} = template) do
    repo().delete(template)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Documents
  # ═══════════════════════════════════════════════════════════════════

  def list_documents(opts \\ []) do
    query = from(d in Document, order_by: [desc: :updated_at])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [d], d.status == ^status)
      end

    repo().all(query)
  end

  def get_document(uuid) do
    repo().get(Document, uuid)
  end

  def get_document!(uuid) do
    repo().get!(Document, uuid)
  end

  def create_document(attrs) do
    %Document{}
    |> Document.changeset(attrs)
    |> repo().insert()
  end

  def update_document(%Document{} = document, attrs) do
    document
    |> Document.changeset(attrs)
    |> repo().update()
  end

  def delete_document(%Document{} = document) do
    repo().delete(document)
  end

  @doc """
  Creates a new document from a template, rendering `{{ variables }}` with Solid.

  ## Parameters

    - `template_uuid` — UUID of the template to clone
    - `variable_values` — map of `%{"variable_name" => "value"}` to substitute
    - `opts` — keyword list with optional `:name` and `:created_by_uuid`

  ## Returns

    - `{:ok, document}` on success
    - `{:error, :template_not_found}` if the template doesn't exist
    - `{:error, changeset}` on validation failure
  """
  def create_document_from_template(template_uuid, variable_values, opts \\ [])
      when is_map(variable_values) do
    case get_template(template_uuid) do
      nil ->
        {:error, :template_not_found}

      %Template{} = template ->
        rendered_html = render_variables(template.content_html, variable_values)

        doc_attrs = %{
          name: Keyword.get(opts, :name, template.name),
          template_uuid: template.uuid,
          content_html: rendered_html,
          content_css: template.content_css,
          content_native: template.content_native,
          variable_values: variable_values,
          header_footer_uuid: template.header_footer_uuid,
          config: template.config,
          created_by_uuid: Keyword.get(opts, :created_by_uuid)
        }

        create_document(doc_attrs)
    end
  end

  defp render_variables(html, variables) when is_binary(html) and map_size(variables) > 0 do
    case Solid.parse(html) do
      {:ok, template} ->
        Solid.render(template, variables)
        |> to_string()

      {:error, _reason} ->
        # Fall back to simple regex substitution if Solid parsing fails
        # (e.g. HTML contains Liquid-incompatible syntax)
        Enum.reduce(variables, html, fn {key, value}, acc ->
          String.replace(acc, ~r/\{\{\s*#{Regex.escape(key)}\s*\}\}/, to_string(value))
        end)
    end
  end

  defp render_variables(html, _variables), do: html
end
