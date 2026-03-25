# PDF Generation Options for PhoenixKit Document Creator

## Current Approach: ChromicPDF (Headless Chrome)

GrapesJS outputs HTML/CSS, and ChromicPDF renders it to PDF via headless Chrome. This gives pixel-perfect fidelity — what users see in the editor is what they get in the PDF.

**Pros:**
- Most accurate HTML/CSS rendering available
- Headers/footers, multi-page, paper sizes all work natively
- Standard approach in the Phoenix ecosystem for HTML-to-PDF
- Lazy startup via `ChromeSupervisor` — Chrome only boots on first PDF export

**Cons:**
- Chrome binary is ~300MB+ on disk
- Memory-hungry (~100-200MB per instance)
- Slow cold start (~2-5s first PDF, faster after)
- External system dependency (Chrome/Chromium must be installed)
- Hard to run in minimal containers or serverless

## Alternatives Considered

### Weasyprint (Python)
- Lighter than Chrome, good CSS support
- Still an external binary dependency (Python + Weasyprint)
- CSS support is good but not as complete as Chrome (no JS, limited flexbox)
- Could be a drop-in replacement for the HTML-to-PDF step
- Elixir integration: shell out to `weasyprint` CLI

### Typst (via typst_elixir)
- Fast, tiny binary, beautiful typographic output
- Own markup language — would need HTML-to-Typst conversion layer
- Great for structured documents (invoices, reports, contracts)
- Not a drop-in replacement — requires rethinking the output pipeline
- Most exciting long-term option if we move away from HTML-based PDF

### pdf (pure Elixir, already in mix.lock)
- Zero external dependencies
- Programmatic API — you draw everything manually (text, lines, images)
- No HTML rendering at all
- Good for simple, structured documents (invoices, labels)
- Not suitable for rendering freeform GrapesJS HTML output

### Gotenberg (Docker microservice)
- Wraps Chrome (and LibreOffice) in a Docker container
- Offloads PDF generation to a separate service
- Cleaner separation of concerns, easier to scale independently
- Adds infrastructure complexity (another container to manage)
- Same Chrome underneath, just containerized
- See [Gotenberg Migration Plan](#gotenberg-migration-plan) below for implementation details

### Remote Chrome (browserless)
- Run Chrome in a container (`browserless/chrome`), keep ChromicPDF in Elixir
- ChromicPDF connects to remote Chrome via `chrome_address` option
- Minimal code changes — same API, different Chrome location
- Still couples app to ChromicPDF library

### wkhtmltopdf
- Deprecated, uses old QtWebKit engine
- Poor CSS3 support
- Do not use for new projects

## Decision Matrix

| Criteria | ChromicPDF | Weasyprint | Typst | pdf (Elixir) | Gotenberg |
|----------|-----------|------------|-------|-------------|-----------|
| HTML fidelity | Best | Good | N/A (own markup) | N/A (manual) | Best |
| Install size | ~300MB | ~50MB | ~30MB | 0 | Docker image |
| Memory usage | High | Medium | Low | Low | High (separate) |
| Cold start | Slow | Medium | Fast | Instant | Slow |
| External deps | Chrome | Python | Typst binary | None | Docker |
| Drop-in replace | Current | Yes | No (rewrite) | No (rewrite) | Yes |

## Recommendation

- **Short term:** Keep ChromicPDF. It works, it's accurate, and GrapesJS demands faithful HTML rendering.
- **Medium term:** Consider Gotenberg if we need to scale PDF generation independently or run in containers without Chrome installed.
- **Long term:** Evaluate Typst if we ever redesign the document output layer. It would mean building a Typst template system alongside (or instead of) GrapesJS HTML output, but the result would be faster, lighter, and more portable.

## Gotenberg Migration Plan

If we migrate from ChromicPDF to Gotenberg, here's what's involved.

### Infrastructure

```yaml
# docker-compose.yml
services:
  gotenberg:
    image: gotenberg/gotenberg:8
    ports:
      - "3000:3000"
```

No Chrome needed in the app Docker image. Gotenberg handles everything.

### Elixir Integration

Gotenberg exposes a REST API. Send HTML, get PDF back. Uses `Req` (already in deps).

```elixir
# Basic HTML-to-PDF
Req.post!("http://gotenberg:3000/forms/chromium/convert/html",
  form_multipart: [
    {"files", {"index.html", html_content}, filename: "index.html"},
    {"paperWidth", "8.27"},
    {"paperHeight", "11.69"},
    {"marginTop", "0.4"},
    {"marginBottom", "0.4"}
  ]
).body
```

Headers/footers are supported — upload `header.html` and `footer.html` as additional files:

```elixir
Req.post!("http://gotenberg:3000/forms/chromium/convert/html",
  form_multipart: [
    {"files", {"index.html", body_html}, filename: "index.html"},
    {"files", {"header.html", header_html}, filename: "header.html"},
    {"files", {"footer.html", footer_html}, filename: "footer.html"},
    {"paperWidth", "8.27"},
    {"paperHeight", "11.69"},
    {"marginTop", "1.0"},
    {"marginBottom", "0.8"}
  ]
).body
```

### Code Changes Required

1. **Drop** `chromic_pdf` from `mix.exs` deps
2. **Delete** `ChromeSupervisor` module entirely
3. **Delete** `chromic_pdf_available?/0` and `chrome_installed?/0` from main module
4. **Rewrite** `EditorPdfHelpers` to POST HTML to Gotenberg via `Req`
5. **Add** Gotenberg URL to app config: `config :phoenix_kit_document_creator, :gotenberg_url, "http://gotenberg:3000"`
6. **Add** `gotenberg` service to docker-compose

### Remote Chrome Alternative (smaller change)

If we want to keep ChromicPDF but just move Chrome out of the app image:

```yaml
# docker-compose.yml
services:
  chrome:
    image: browserless/chrome
    ports:
      - "3000:3000"
    environment:
      - CONNECTION_TIMEOUT=120000
```

```elixir
# Point ChromicPDF at remote Chrome
ChromicPDF.print_to_pdf({:html, html},
  chrome_address: "http://chrome:3000"
)
```

This is a smaller change (just config) but still couples us to ChromicPDF.

## Key Question for Future

Do users need pixel-perfect HTML-to-PDF (keep Chrome), or could we generate PDFs programmatically from structured data (switch to Typst or pure Elixir)?

The answer depends on how much creative freedom users need in the editor vs. how structured the documents actually are in practice.
