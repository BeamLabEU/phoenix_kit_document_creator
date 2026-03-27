defmodule PhoenixKitDocumentCreator.Web.EditorPdfHelpers do
  @moduledoc """
  Shared PDF generation helpers used by all editor pages (template, document,
  header/footer, and testing editors).

  Generates PDFs by sending HTML to a Gotenberg instance via its HTTP API.
  Supports both plain text headers/footers (`:header_text`/`:footer_text`)
  and rich HTML headers/footers (`:header_html`/`:footer_html`).
  Documents store baked header/footer content, so PDF generation reads
  HTML, CSS, and height directly from the document record — no FK lookups needed.

  ## Configuration

  Set the Gotenberg base URL in your config:

      config :phoenix_kit_document_creator, :gotenberg_url, "http://gotenberg:3000"

  ## Units

  Three unit systems are used across the stack, all based on the CSS
  standard of 1in = 96px:

    - **GrapesJS canvas** (`editor_hooks.js`): CSS pixels (e.g. A4 = 794×1123px)
    - **Gotenberg paper size** (this module): inches for `paperWidth`/`paperHeight`
    - **Header/footer heights** (this module): CSS unit strings
      like `"25mm"`, converted to inches for Gotenberg's margin fields

  All three resolve to the same physical dimensions (1mm = 3.7795px = 1/25.4in).
  """

  @gotenberg_convert_html "/forms/chromium/convert/html"

  # These styles must match CANVAS_STYLES in editor_hooks.js so the
  # editor preview and PDF output look identical.
  @body_styles """
  <style>
    body { font-family: Inter, -apple-system, Helvetica, Arial, sans-serif; font-size: 14px; line-height: 1.7; color: #1a1a1a; margin: 0; padding: 0; }
    h1 { font-size: 28px; font-weight: 700; margin: 0 0 12px 0; line-height: 1.3; }
    h2 { font-size: 20px; font-weight: 600; margin: 24px 0 8px 0; line-height: 1.3; }
    h3 { font-size: 16px; font-weight: 600; margin: 20px 0 6px 0; }
    p { margin: 0 0 12px 0; }
    ul, ol { margin: 0 0 12px 0; padding-left: 24px; }
    li { margin-bottom: 4px; }
    table { width: 100%; border-collapse: collapse; margin: 16px 0; }
    th { background: #f8f9fa; text-align: left; padding: 10px 14px; font-size: 13px; font-weight: 600; border-bottom: 2px solid #e0e0e0; }
    td { padding: 10px 14px; border-bottom: 1px solid #eee; font-size: 13px; }
    blockquote { border-left: 4px solid #d0d0d0; margin: 16px 0; padding: 8px 16px; color: #555; font-style: italic; }
    hr { border: none; border-top: 2px solid #e0e0e0; margin: 24px 0; }
    img { max-width: 100%; height: auto; border-radius: 4px; }
    a { color: #2563eb; text-decoration: underline; }
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
    html = strip_body_wrapper(html)
    header_html = Keyword.get(opts, :header_html, "") |> strip_body_wrapper()
    footer_html = Keyword.get(opts, :footer_html, "") |> strip_body_wrapper()
    header_css = Keyword.get(opts, :header_css, "")
    footer_css = Keyword.get(opts, :footer_css, "")
    header_text = Keyword.get(opts, :header_text, "")
    footer_text = Keyword.get(opts, :footer_text, "")
    header_height = Keyword.get(opts, :header_height)
    footer_height = Keyword.get(opts, :footer_height)

    paper_size = Keyword.get(opts, :paper_size, "a4")

    cond do
      rich_content?(header_html) or rich_content?(footer_html) ->
        generate_with_rich_hf(
          html,
          header_html,
          header_css,
          footer_html,
          footer_css,
          paper_size,
          header_height,
          footer_height
        )

      has_text?(header_text) or has_text?(footer_text) ->
        generate_with_text_hf(html, header_text, footer_text, paper_size)

      true ->
        body_html = full_html_document(@body_styles <> html)

        post_to_gotenberg([
          file_part("index.html", body_html),
          {"paperWidth", to_string(paper_width(paper_size))},
          {"paperHeight", to_string(paper_height(paper_size))},
          {"marginTop", "0"},
          {"marginBottom", "0"},
          {"marginLeft", "0"},
          {"marginRight", "0"},
          {"printBackground", "true"}
        ])
    end
  end

  @doc """
  Generates a PDF thumbnail data URI for embedding in an iframe srcdoc.

  Returns the body HTML + CSS as a self-contained HTML document that can
  be used as an iframe `srcdoc` attribute for a scaled preview.
  """
  def generate_thumbnail_html(html, opts \\ []) do
    css = Keyword.get(opts, :css, "")
    css_block = sanitize_thumbnail_css(css)
    full_html = @body_styles <> css_block <> html
    {:ok, "data:text/html;base64," <> Base.encode64(full_html)}
  end

  # --- Rich HTML header/footer ---

  defp generate_with_rich_hf(
         html,
         header_html,
         header_css,
         footer_html,
         footer_css,
         paper_size,
         header_height,
         footer_height
       ) do
    has_header = rich_content?(header_html)
    has_footer = rich_content?(footer_html)

    h_height = if(has_header, do: header_height || "25mm", else: "0")
    f_height = if(has_footer, do: footer_height || "20mm", else: "0")

    margin_top = css_to_inches(h_height)
    margin_bottom = css_to_inches(f_height)

    body_html = full_html_document(@body_styles <> html)

    parts =
      [
        file_part("index.html", body_html),
        {"paperWidth", to_string(paper_width(paper_size))},
        {"paperHeight", to_string(paper_height(paper_size))},
        {"marginTop", to_string(margin_top)},
        {"marginBottom", to_string(margin_bottom)},
        {"marginLeft", "0"},
        {"marginRight", "0"},
        {"printBackground", "true"}
      ]
      |> maybe_add_hf_file("header.html", has_header, header_html, header_css, h_height)
      |> maybe_add_hf_file("footer.html", has_footer, footer_html, footer_css, f_height)

    post_to_gotenberg(parts)
  end

  defp maybe_add_hf_file(parts, _filename, false, _html, _css, _height), do: parts

  defp maybe_add_hf_file(parts, filename, true, html, css, height) do
    hf_html = build_hf_document(html, css, height)
    parts ++ [file_part(filename, hf_html)]
  end

  defp build_hf_document(html, css, height) do
    css_block = sanitize_hf_css(css)

    """
    <!DOCTYPE html>
    <html><head>
    <style>
      body { margin: 0; padding: 0; }
      .hf-wrapper {
        width: 100%;
        height: #{height};
        font-family: Helvetica, Arial, sans-serif;
        font-size: 9pt;
        color: #333;
        box-sizing: border-box;
        position: relative;
      }
      .hf-wrapper img { max-height: 18mm; width: auto; }
    </style>
    #{css_block}
    </head>
    <body>
      <div class="hf-wrapper">#{constrain_images(html)}</div>
    </body></html>
    """
  end

  # --- Plain text header/footer ---

  defp generate_with_text_hf(html, header_text, footer_text, paper_size) do
    has_header = has_text?(header_text)
    has_footer = has_text?(footer_text)

    h_height = if(has_header, do: "20mm", else: "0")
    f_height = if(has_footer, do: "15mm", else: "0")

    margin_top = css_to_inches(h_height)
    margin_bottom = css_to_inches(f_height)

    body_html = full_html_document(@body_styles <> html)

    parts =
      [
        file_part("index.html", body_html),
        {"paperWidth", to_string(paper_width(paper_size))},
        {"paperHeight", to_string(paper_height(paper_size))},
        {"marginTop", to_string(margin_top)},
        {"marginBottom", to_string(margin_bottom)},
        {"marginLeft", "0"},
        {"marginRight", "0"},
        {"printBackground", "true"}
      ]
      |> maybe_add_text_hf("header.html", has_header, header_text, :header)
      |> maybe_add_text_hf("footer.html", has_footer, footer_text, :footer)

    post_to_gotenberg(parts)
  end

  defp maybe_add_text_hf(parts, _filename, false, _text, _type), do: parts

  defp maybe_add_text_hf(parts, filename, true, text, type) do
    html = text_hf_document(text, type)
    parts ++ [file_part(filename, html)]
  end

  defp text_hf_document(text, :header) do
    """
    <!DOCTYPE html>
    <html><head><style>
      body { margin: 0; padding: 0; }
    </style></head>
    <body>
      <div style="width:100%;font-family:Helvetica,Arial,sans-serif;font-size:9px;padding:4px 40px;display:flex;justify-content:space-between;align-items:center;color:#666;border-bottom:1px solid #e0e0e0;">
        <span>#{escape_html(text)}</span>
        <span style="font-size:8px;color:#999;"><span class="date"></span></span>
      </div>
    </body></html>
    """
  end

  defp text_hf_document(text, :footer) do
    """
    <!DOCTYPE html>
    <html><head><style>
      body { margin: 0; padding: 0; }
    </style></head>
    <body>
      <div style="width:100%;font-family:Helvetica,Arial,sans-serif;font-size:9px;padding:4px 40px;display:flex;justify-content:space-between;align-items:center;color:#666;border-top:1px solid #e0e0e0;">
        <span>#{escape_html(text)}</span>
        <span>Page <span class="pageNumber"></span> of <span class="totalPages"></span></span>
      </div>
    </body></html>
    """
  end

  # --- Gotenberg HTTP client ---

  defp post_to_gotenberg(parts) do
    url = gotenberg_url() <> @gotenberg_convert_html

    # Gotenberg expects files under the "files" field name as multipart uploads,
    # and config values as plain form fields.
    multipart =
      Enum.map(parts, fn
        {:file, filename, content} ->
          {:files, {content, filename: filename, content_type: "text/html"}}

        {key, value} ->
          {key, value}
      end)

    case Req.post(url, form_multipart: multipart, pool_timeout: 5_000, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: pdf_bytes}} ->
        {:ok, Base.encode64(pdf_bytes)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Gotenberg returned #{status}: #{inspect(body)}"}

      {:error, exception} ->
        {:error, "Gotenberg request failed: #{Exception.message(exception)}"}
    end
  end

  defp gotenberg_url do
    Application.get_env(:phoenix_kit_document_creator, :gotenberg_url, "http://gotenberg:3000")
  end

  defp file_part(filename, content) do
    {:file, filename, content}
  end

  defp full_html_document(body_content) do
    """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"></head>
    <body>#{body_content}</body></html>
    """
  end

  # --- CSS sanitization ---

  # Strip GrapesJS editor-context CSS rules that break header/footer
  # rendering (body resets, universal selectors, wrapper height/overflow),
  # but keep element-specific rules needed for positioning.
  defp sanitize_hf_css(css) when is_binary(css) and css != "" do
    sanitized =
      css
      # Remove * { ... } reset rules
      |> String.replace(~r/\*\s*\{[^}]*\}/, "")
      # Remove body { ... } rules
      |> String.replace(~r/body\s*\{[^}]*\}/, "")
      |> String.trim()

    # Remove the wrapper element's rule (first ID selector — it's the
    # stripped <body> wrapper and its height:100%/overflow:hidden breaks
    # header/footer rendering)
    sanitized =
      case Regex.run(~r/\A\s*(#\w+)\s*\{/, sanitized) do
        [_, wrapper_id] ->
          String.replace(sanitized, ~r/#{Regex.escape(wrapper_id)}\s*\{[^}]*\}/, "",
            global: false
          )

        _ ->
          sanitized
      end

    case String.trim(sanitized) do
      "" -> ""
      s -> "<style>#{s}</style>"
    end
  end

  defp sanitize_hf_css(_), do: ""

  # Strip @import and url() from thumbnail CSS to prevent data exfiltration.
  # Thumbnails are also sandboxed (sandbox="") but this adds defense-in-depth.
  defp sanitize_thumbnail_css(css) when is_binary(css) and css != "" do
    sanitized =
      css
      |> String.replace(~r/@import\s[^;]*;/i, "")
      |> String.replace(~r/url\s*\([^)]*\)/i, "url()")
      |> String.trim()

    case sanitized do
      "" -> ""
      s -> "<style>#{s}</style>"
    end
  end

  defp sanitize_thumbnail_css(_), do: ""

  defp constrain_images(html) when is_binary(html) do
    Regex.replace(~r/<img([^>]*)>/i, html, fn full, attrs ->
      cond do
        String.contains?(attrs, "max-height") ->
          full

        String.contains?(attrs, "style=\"") ->
          # Inject constraints into existing style attribute
          String.replace(full, ~r/style="([^"]*)"/i, "style=\"max-height:18mm;width:auto;\\1\"")

        true ->
          "<img style=\"max-height:18mm;width:auto;\"#{attrs}>"
      end
    end)
  end

  defp constrain_images(_), do: ""

  # --- Shared helpers ---

  # GrapesJS getHtml() wraps content in <body id="...">...</body>.
  # Convert to <div> so we don't produce nested <body> tags in the PDF,
  # which causes Chrome to ignore page margins. The id and attributes
  # are preserved so GrapesJS CSS selectors (e.g. #iluw) still match.
  # Note: JS may append <style>...</style> after </body>, so we can't
  # anchor the closing tag regex to end-of-string.
  defp strip_body_wrapper(html) when is_binary(html) do
    html
    |> String.replace(~r/<body\b/s, "<div", global: false)
    |> String.replace("</body>", "</div>", global: false)
  end

  defp strip_body_wrapper(html), do: html

  defp rich_content?(html) when is_binary(html) do
    trimmed = String.trim(html)
    trimmed != "" and trimmed not in ["<p></p>", "<p><br></p>", "<p><br/></p>"]
  end

  defp rich_content?(_), do: false

  defp has_text?(text), do: is_binary(text) and text != ""

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_html(_), do: ""

  # Dimensions in inches for Gotenberg's paperWidth/paperHeight
  defp paper_width("a4"), do: 8.27
  defp paper_width("letter"), do: 8.5
  defp paper_width("legal"), do: 8.5
  defp paper_width("tabloid"), do: 11.0
  defp paper_width(_), do: 8.27

  defp paper_height("a4"), do: 11.69
  defp paper_height("letter"), do: 11.0
  defp paper_height("legal"), do: 14.0
  defp paper_height("tabloid"), do: 17.0
  defp paper_height(_), do: 11.69

  # Convert CSS length (e.g. "25mm", "1in", "2cm") to inches for Gotenberg
  defp css_to_inches("0"), do: 0

  defp css_to_inches(val) when is_binary(val) do
    cond do
      String.ends_with?(val, "mm") ->
        {num, _} = Float.parse(String.trim_trailing(val, "mm"))
        num / 25.4

      String.ends_with?(val, "cm") ->
        {num, _} = Float.parse(String.trim_trailing(val, "cm"))
        num / 2.54

      String.ends_with?(val, "in") ->
        {num, _} = Float.parse(String.trim_trailing(val, "in"))
        num

      String.ends_with?(val, "px") ->
        {num, _} = Float.parse(String.trim_trailing(val, "px"))
        num / 96.0

      true ->
        # Default: assume mm
        case Float.parse(val) do
          {num, _} -> num / 25.4
          :error -> 0
        end
    end
  end

  defp css_to_inches(_), do: 0
end
