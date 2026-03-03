defmodule PhoenixKitDocForge.TemplateBuilder.PdfRenderer do
  @moduledoc """
  Renders template blocks to PDF via ChromicPDF.

  Pipeline: Blocks → HTML body + header/footer HTML → variable substitution via Solid → ChromicPDF → PDF binary.
  """

  alias PhoenixKitDocForge.TemplateBuilder.Block

  @body_styles """
  <style>
    body {
      font-family: Helvetica, Arial, sans-serif;
      font-size: 11pt;
      line-height: 1.6;
      color: #1a1a1a;
      margin: 0;
      padding: 0 40px;
    }
    h1 { font-size: 22pt; margin: 0 0 4px 0; }
    h2 { font-size: 14pt; color: #333; margin: 24px 0 8px 0; }
    h3 { font-size: 12pt; color: #444; margin: 20px 0 6px 0; }
    p { margin: 0 0 8px 0; }
    hr { border: none; border-top: 1px solid #ddd; margin: 16px 0; }
    table { width: 100%; border-collapse: collapse; margin: 12px 0; }
    th { background: #f5f5f5; text-align: left; padding: 8px 12px; font-size: 10pt; border-bottom: 2px solid #ddd; }
    td { padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 10pt; }
    tr:last-child td { font-weight: bold; border-top: 2px solid #333; border-bottom: none; }
    ul, ol { margin: 4px 0 12px 0; padding-left: 24px; }
    li { margin-bottom: 4px; font-size: 10pt; }
    .signature-block { display: flex; gap: 60px; margin-top: 20px; }
    .signature { flex: 1; }
    .signature-line { border-bottom: 1px solid #333; height: 40px; margin-bottom: 4px; }
    .signature-name { font-size: 9pt; color: #666; }
    .image-placeholder { margin: 12px 0; }
  </style>
  """

  @doc """
  Renders blocks to a PDF binary.

  Returns `{:ok, pdf_binary}` or `{:error, reason}`.
  """
  def render(blocks, variables, header_html, footer_html, config \\ %{}) do
    config = normalize_config(config)

    body_html =
      blocks
      |> Enum.map(&Block.render_to_html/1)
      |> Enum.join("\n")
      |> substitute_variables(variables)
      |> replace_image_placeholders(variables)

    header = substitute_variables(header_html || "", variables)
    footer = substitute_variables(footer_html || "", variables)

    with :ok <- PhoenixKitDocForge.ChromeSupervisor.ensure_started() do
      opts =
        [
          content: @body_styles <> body_html,
          header: header,
          footer: footer,
          size: config.paper_size
        ]
        |> maybe_add_header_height(config)
        |> maybe_add_footer_height(config)

      %{source: source, opts: print_opts} = ChromicPDF.Template.source_and_options(opts)

      ChromicPDF.print_to_pdf(source, print_opts)
    end
  end

  @doc """
  Renders blocks to HTML string (for preview, no PDF generation).
  """
  def render_to_html(blocks, variables) do
    blocks
    |> Enum.map(&Block.render_to_html/1)
    |> Enum.join("\n")
    |> substitute_variables(variables)
    |> replace_image_placeholders(variables)
    |> then(&(@body_styles <> &1))
  end

  defp substitute_variables(template, variables) when is_binary(template) do
    case Solid.parse(template) do
      {:ok, parsed} ->
        parsed |> Solid.render!(variables) |> to_string()

      {:error, _reason} ->
        # Fallback: simple regex replacement for robustness
        Regex.replace(~r/\{\{\s*(\w+)\s*\}\}/, template, fn _full, name ->
          Map.get(variables, name, "{{#{name}}}")
        end)
    end
  end

  defp substitute_variables(template, _variables), do: template || ""

  # Swaps SVG placeholder images with real image URLs when a variable value is provided.
  # Matches <img> tags whose src is a data:image/svg+xml URI and whose alt contains {{ var }}.
  defp replace_image_placeholders(html, variables) when is_binary(html) do
    Regex.replace(
      ~r/<img([^>]*?)src="data:image\/svg\+xml[^"]*"([^>]*?)alt="([^"]*)"([^>]*?)>/,
      html,
      fn full, pre, mid, alt, post ->
        case Regex.run(~r/\{\{\s*(\w+)\s*\}\}/, alt) do
          [_match, var_name] ->
            case Map.get(variables, var_name) do
              url when is_binary(url) and url != "" ->
                ~s(<img#{pre}src="#{url}"#{mid}alt="#{var_name}"#{post}>)

              _ ->
                full
            end

          _ ->
            full
        end
      end
    )
  end

  defp replace_image_placeholders(html, _variables), do: html

  defp normalize_config(config) when is_map(config) do
    %{
      paper_size: Map.get(config, :paper_size, :a4),
      orientation: Map.get(config, :orientation, "portrait"),
      header_height: Map.get(config, :header_height, "25mm"),
      footer_height: Map.get(config, :footer_height, "20mm")
    }
  end

  defp maybe_add_header_height(opts, %{header_height: h}) when h not in [nil, "", "0"],
    do: Keyword.put(opts, :header_height, h)

  defp maybe_add_header_height(opts, _), do: opts

  defp maybe_add_footer_height(opts, %{footer_height: h}) when h not in [nil, "", "0"],
    do: Keyword.put(opts, :footer_height, h)

  defp maybe_add_footer_height(opts, _), do: opts
end
