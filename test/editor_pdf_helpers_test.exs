defmodule PhoenixKitDocumentCreator.Web.EditorPdfHelpersTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Web.EditorPdfHelpers

  describe "generate_thumbnail_html/2" do
    test "returns {:ok, data_uri} tuple" do
      assert {:ok, data_uri} = EditorPdfHelpers.generate_thumbnail_html("<p>Hello</p>")
      assert String.starts_with?(data_uri, "data:text/html;base64,")
    end

    test "the decoded HTML contains the original content" do
      {:ok, data_uri} = EditorPdfHelpers.generate_thumbnail_html("<h1>Title</h1>")
      base64 = String.replace_prefix(data_uri, "data:text/html;base64,", "")
      decoded = Base.decode64!(base64)
      assert String.contains?(decoded, "<h1>Title</h1>")
    end

    test "the decoded HTML contains body styles" do
      {:ok, data_uri} = EditorPdfHelpers.generate_thumbnail_html("<p>Test</p>")
      base64 = String.replace_prefix(data_uri, "data:text/html;base64,", "")
      decoded = Base.decode64!(base64)
      assert String.contains?(decoded, "<style>")
      assert String.contains?(decoded, "font-family")
    end

    test "includes custom CSS when provided" do
      {:ok, data_uri} =
        EditorPdfHelpers.generate_thumbnail_html("<p>Test</p>", css: ".custom { color: red; }")

      base64 = String.replace_prefix(data_uri, "data:text/html;base64,", "")
      decoded = Base.decode64!(base64)
      assert String.contains?(decoded, ".custom { color: red; }")
    end

    test "omits extra style block when css is empty string" do
      {:ok, data_uri} = EditorPdfHelpers.generate_thumbnail_html("<p>Test</p>", css: "")
      base64 = String.replace_prefix(data_uri, "data:text/html;base64,", "")
      decoded = Base.decode64!(base64)
      # Should contain exactly one <style> block (the body styles), not two
      # Count occurrences of "<style>"
      count = length(String.split(decoded, "<style>")) - 1
      assert count == 1
    end

    test "omits extra style block when css is not provided" do
      {:ok, data_uri} = EditorPdfHelpers.generate_thumbnail_html("<p>Test</p>")
      base64 = String.replace_prefix(data_uri, "data:text/html;base64,", "")
      decoded = Base.decode64!(base64)
      count = length(String.split(decoded, "<style>")) - 1
      assert count == 1
    end

    test "works with empty HTML" do
      assert {:ok, data_uri} = EditorPdfHelpers.generate_thumbnail_html("")
      assert String.starts_with?(data_uri, "data:text/html;base64,")
    end

    test "handles body-wrapped HTML from GrapesJS" do
      # GrapesJS wraps content in <body id="...">...</body>
      # generate_thumbnail_html does NOT call strip_body_wrapper (only generate_pdf does),
      # so the body tags pass through. This is fine for thumbnails since they render in iframes.
      html = ~s(<body id="iluw"><p>Content</p></body>)
      {:ok, data_uri} = EditorPdfHelpers.generate_thumbnail_html(html)
      base64 = String.replace_prefix(data_uri, "data:text/html;base64,", "")
      decoded = Base.decode64!(base64)
      assert String.contains?(decoded, "Content")
    end
  end

  describe "module interface" do
    test "module compiles and is loaded" do
      # Ensure the module is available
      assert Code.ensure_loaded?(EditorPdfHelpers)
    end

    test "exports generate_pdf function" do
      exports = EditorPdfHelpers.__info__(:functions)
      assert {:generate_pdf, 1} in exports or {:generate_pdf, 2} in exports
    end

    test "exports generate_thumbnail_html function" do
      exports = EditorPdfHelpers.__info__(:functions)
      assert {:generate_thumbnail_html, 1} in exports or {:generate_thumbnail_html, 2} in exports
    end
  end
end
