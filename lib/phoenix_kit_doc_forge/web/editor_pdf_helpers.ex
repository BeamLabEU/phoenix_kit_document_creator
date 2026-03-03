defmodule PhoenixKitDocForge.Web.EditorPdfHelpers do
  @moduledoc """
  Shared PDF generation helpers for editor test pages.

  Provides header/footer support via ChromicPDF.Template.
  Supports both plain text headers/footers (`:header_text`/`:footer_text`)
  and rich HTML headers/footers (`:header_html`/`:footer_html`).
  """

  @body_styles """
  <style>
    body { font-family: Helvetica, Arial, sans-serif; font-size: 11pt; line-height: 1.6; color: #1a1a1a; margin: 0; padding: 0 40px; }
    h1 { font-size: 22pt; margin: 0 0 4px 0; }
    h2 { font-size: 14pt; color: #333; margin: 24px 0 8px 0; }
    table { width: 100%; border-collapse: collapse; margin: 12px 0; }
    th { background: #f5f5f5; text-align: left; padding: 8px 12px; font-size: 10pt; border-bottom: 2px solid #ddd; }
    td { padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 10pt; }
    blockquote { border-left: 4px solid #ccc; margin: 16px 0; padding: 8px 16px; color: #555; }
  </style>
  """

  @doc """
  Generates a PDF from HTML content with optional header and footer.

  Accepts either plain text or rich HTML for headers/footers:
  - `:header_html` / `:footer_html` — rich HTML (takes precedence)
  - `:header_text` / `:footer_text` — plain text (fallback)

  Returns `{:ok, base64_pdf}` or `{:error, reason}`.
  """
  def generate_pdf(html, opts \\ []) do
    header_html = Keyword.get(opts, :header_html, "")
    footer_html = Keyword.get(opts, :footer_html, "")
    header_text = Keyword.get(opts, :header_text, "")
    footer_text = Keyword.get(opts, :footer_text, "")

    with :ok <- PhoenixKitDocForge.ChromeSupervisor.ensure_started() do
      cond do
        rich_content?(header_html) or rich_content?(footer_html) ->
          generate_with_rich_template(html, header_html, footer_html)

        has_text?(header_text) or has_text?(footer_text) ->
          generate_with_text_template(html, header_text, footer_text)

        true ->
          ChromicPDF.print_to_pdf({:html, @body_styles <> html})
      end
    end
  end

  # --- Rich HTML header/footer ---

  defp generate_with_rich_template(html, header_html, footer_html) do
    header = if rich_content?(header_html), do: rich_header_wrapper(header_html), else: ""
    footer = if rich_content?(footer_html), do: rich_footer_wrapper(footer_html), else: ""

    template_opts =
      [content: @body_styles <> html, size: :a4]
      |> maybe_add(:header, header)
      |> maybe_add(:footer, footer)
      |> maybe_add(:header_height, if(header != "", do: "25mm"))
      |> maybe_add(:footer_height, if(footer != "", do: "20mm"))

    %{source: source, opts: print_opts} = ChromicPDF.Template.source_and_options(template_opts)
    ChromicPDF.print_to_pdf(source, print_opts)
  end

  defp rich_header_wrapper(html) do
    """
    <div style="width:100%;font-family:Helvetica,Arial,sans-serif;font-size:9pt;padding:4px 40px;color:#333;border-bottom:1px solid #e0e0e0;overflow:hidden;box-sizing:border-box;">
      #{constrain_images(html)}
    </div>
    """
  end

  defp rich_footer_wrapper(html) do
    """
    <div style="width:100%;font-family:Helvetica,Arial,sans-serif;font-size:9pt;padding:4px 40px;color:#333;border-top:1px solid #e0e0e0;overflow:hidden;box-sizing:border-box;">
      #{constrain_images(html)}
    </div>
    """
  end

  defp constrain_images(html) when is_binary(html) do
    Regex.replace(~r/<img([^>]*)>/i, html, fn full, attrs ->
      if String.contains?(attrs, "max-height") do
        full
      else
        "<img style=\"max-height:18mm;width:auto;float:left;margin-right:10px;margin-bottom:4px;\"#{attrs}>"
      end
    end)
  end

  defp constrain_images(_), do: ""

  defp rich_content?(html) when is_binary(html) do
    trimmed = String.trim(html)
    trimmed != "" and trimmed not in ["<p></p>", "<p><br></p>", "<p><br/></p>"]
  end

  defp rich_content?(_), do: false

  # --- Plain text header/footer (backward compatible) ---

  defp generate_with_text_template(html, header_text, footer_text) do
    header = if has_text?(header_text), do: text_header_template(header_text), else: ""
    footer = if has_text?(footer_text), do: text_footer_template(footer_text), else: ""

    template_opts =
      [content: @body_styles <> html, size: :a4]
      |> maybe_add(:header, header)
      |> maybe_add(:footer, footer)
      |> maybe_add(:header_height, if(header != "", do: "20mm"))
      |> maybe_add(:footer_height, if(footer != "", do: "15mm"))

    %{source: source, opts: print_opts} = ChromicPDF.Template.source_and_options(template_opts)
    ChromicPDF.print_to_pdf(source, print_opts)
  end

  defp text_header_template(text) do
    """
    <div style="width:100%;font-family:Helvetica,Arial,sans-serif;font-size:9px;padding:4px 40px;display:flex;justify-content:space-between;align-items:center;color:#666;border-bottom:1px solid #e0e0e0;">
      <span>#{escape_html(text)}</span>
      <span style="font-size:8px;color:#999;"><span class="date"></span></span>
    </div>
    """
  end

  defp text_footer_template(text) do
    """
    <div style="width:100%;font-family:Helvetica,Arial,sans-serif;font-size:9px;padding:4px 40px;display:flex;justify-content:space-between;align-items:center;color:#666;border-top:1px solid #e0e0e0;">
      <span>#{escape_html(text)}</span>
      <span>Page <span class="pageNumber"></span> of <span class="totalPages"></span></span>
    </div>
    """
  end

  # --- Shared helpers ---

  defp has_text?(text), do: is_binary(text) and text != ""

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, ""), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_html(_), do: ""
end
