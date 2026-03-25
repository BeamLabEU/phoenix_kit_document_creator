defmodule PhoenixKitDocumentCreator.Documents do
  @moduledoc """
  Context module for managing templates, documents, headers, and footers.

  Provides CRUD operations for all three resource types plus the
  `create_document_from_template/3` workflow that renders template variables
  via Solid and bakes header/footer content (HTML, CSS, height) directly into
  the new document. This means documents are fully self-contained after
  creation — deleting the source template, header, or footer will not affect
  existing documents.
  """
  import Ecto.Query, warn: false

  alias PhoenixKitDocumentCreator.Schemas.{Document, HeaderFooter, Template}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ═══════════════════════════════════════════════════════════════════
  # Headers & Footers
  # ═══════════════════════════════════════════════════════════════════

  def list_headers do
    HeaderFooter
    |> where(type: "header")
    |> order_by(asc: :name)
    |> repo().all()
  end

  def list_footers do
    HeaderFooter
    |> where(type: "footer")
    |> order_by(asc: :name)
    |> repo().all()
  end

  def get_header_footer(uuid), do: repo().get(HeaderFooter, uuid)

  def get_header_footer!(uuid), do: repo().get!(HeaderFooter, uuid)

  def create_header(attrs) do
    %HeaderFooter{}
    |> HeaderFooter.changeset(Map.put(attrs, :type, "header"))
    |> repo().insert()
  end

  def create_footer(attrs) do
    %HeaderFooter{}
    |> HeaderFooter.changeset(Map.put(attrs, :type, "footer"))
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
    query = from(t in Template, order_by: [desc: :updated_at], preload: [:header, :footer])

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [t], t.status != "trashed")
        status -> where(query, [t], t.status == ^status)
      end

    repo().all(query)
  end

  def published_templates do
    list_templates()
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
        template
        |> build_document_attrs(variable_values, opts)
        |> create_document()
    end
  end

  defp build_document_attrs(template, variable_values, opts) do
    header = load_header_footer(template.header_uuid)
    footer = load_header_footer(template.footer_uuid)

    %{
      name: Keyword.get(opts, :name, template.name),
      template_uuid: template.uuid,
      content_html: render_variables(template.content_html, variable_values),
      content_css: template.content_css,
      content_native: template.content_native,
      variable_values: variable_values,
      config: template.config,
      created_by_uuid: Keyword.get(opts, :created_by_uuid)
    }
    |> Map.merge(bake_hf(:header, header))
    |> Map.merge(bake_hf(:footer, footer))
  end

  defp bake_hf(:header, nil), do: %{header_html: "", header_css: "", header_height: "25mm"}

  defp bake_hf(:header, hf),
    do: %{
      header_html: hf.html || "",
      header_css: hf.css || "",
      header_height: hf.height || "25mm"
    }

  defp bake_hf(:footer, nil), do: %{footer_html: "", footer_css: "", footer_height: "20mm"}

  defp bake_hf(:footer, hf),
    do: %{
      footer_html: hf.html || "",
      footer_css: hf.css || "",
      footer_height: hf.height || "20mm"
    }

  defp load_header_footer(nil), do: nil
  defp load_header_footer(""), do: nil
  defp load_header_footer(uuid), do: get_header_footer(uuid)

  defp render_variables(html, variables) when is_binary(html) and map_size(variables) > 0 do
    case Solid.parse(html) do
      {:ok, template} ->
        case Solid.render(template, variables) do
          {:ok, result, _warnings} -> to_string(result)
          {:error, _errors, result} -> to_string(result)
        end

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
