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

## Key Question for Future

Do users need pixel-perfect HTML-to-PDF (keep Chrome), or could we generate PDFs programmatically from structured data (switch to Typst or pure Elixir)?

The answer depends on how much creative freedom users need in the editor vs. how structured the documents actually are in practice.
