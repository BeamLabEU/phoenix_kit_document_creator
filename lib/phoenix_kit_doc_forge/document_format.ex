defmodule PhoenixKitDocForge.DocumentFormat do
  @moduledoc """
  Standardized document format for editor-agnostic storage.

  All WYSIWYG editors produce and consume HTML. This format wraps editor output
  in a consistent structure that can be stored as JSON in a database column and
  loaded into any editor later.

  ## Switching Editors

  To switch from one editor to another, load `content_html` into the target editor.
  All editors accept HTML import. The native format is preserved for round-trip
  fidelity within the original editor but ignored by others.
  """

  @current_version 1

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          content_html: String.t(),
          content_text: String.t(),
          content_native: map() | nil,
          native_format: String.t() | nil,
          variables: [String.t()],
          header_html: String.t() | nil,
          footer_html: String.t() | nil,
          config: map(),
          metadata: map()
        }

  @enforce_keys [:content_html]
  defstruct schema_version: @current_version,
            content_html: "",
            content_text: "",
            content_native: nil,
            native_format: nil,
            variables: [],
            header_html: nil,
            footer_html: nil,
            config: %{paper_size: "a4", orientation: "portrait"},
            metadata: %{}

  @doc "Creates a new DocumentFormat from editor HTML output."
  def new(content_html, opts \\ []) do
    %__MODULE__{
      content_html: content_html,
      content_text: strip_html(content_html),
      content_native: Keyword.get(opts, :native),
      native_format: Keyword.get(opts, :native_format),
      variables: extract_variables(content_html),
      header_html: Keyword.get(opts, :header_html),
      footer_html: Keyword.get(opts, :footer_html),
      config: Keyword.get(opts, :config, %{paper_size: "a4", orientation: "portrait"}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Serializes to a JSON-compatible map for DB storage."
  def to_json(%__MODULE__{} = doc) do
    doc
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  @doc "Deserializes from a JSON map."
  def from_json(map) when is_map(map) do
    %__MODULE__{
      schema_version: Map.get(map, "schema_version", @current_version),
      content_html: Map.get(map, "content_html", ""),
      content_text: Map.get(map, "content_text", ""),
      content_native: Map.get(map, "content_native"),
      native_format: Map.get(map, "native_format"),
      variables: Map.get(map, "variables", []),
      header_html: Map.get(map, "header_html"),
      footer_html: Map.get(map, "footer_html"),
      config: Map.get(map, "config", %{}),
      metadata: Map.get(map, "metadata", %{})
    }
  end

  @doc "Extracts `{{ variable }}` patterns from HTML content."
  def extract_variables(html) when is_binary(html) do
    ~r/\{\{\s*(\w+)\s*\}\}/
    |> Regex.scan(html)
    |> Enum.map(fn [_full, name] -> name end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def extract_variables(_), do: []

  @doc "Strips HTML tags to produce plain text for search/indexing."
  def strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/(?:p|div|h[1-6]|li|tr|td|th)>/, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/&[a-z]+;/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  def strip_html(_), do: ""

  @doc "Pretty-prints the format as JSON string for display."
  def to_json_string(%__MODULE__{} = doc) do
    doc |> to_json() |> Jason.encode!(pretty: true)
  end

  @doc "Returns sample Service Agreement HTML for editor testing."
  def sample_html do
    """
    <h1>Service Agreement</h1>
    <p>Agreement No. SA-2026-0042 — Effective February 28, 2026</p>

    <h2>1. Parties</h2>
    <p><strong>Provider:</strong> {{ company }}<br>123 Innovation Drive, San Francisco, CA 94102</p>
    <p><strong>Client:</strong> {{ client_name }}<br>456 Business Avenue, New York, NY 10001</p>

    <h2>2. Scope of Services</h2>
    <p>The Provider agrees to deliver the following software development services to the Client, as described in this agreement and any attached statements of work.</p>
    <p>All deliverables shall meet the quality standards outlined in Section 3 and shall be completed within the timeline specified in Section 4.</p>

    <h2>3. Pricing</h2>
    <table>
      <thead>
        <tr><th>Service</th><th>Hours</th><th>Rate</th><th>Amount</th></tr>
      </thead>
      <tbody>
        <tr><td>Backend Development</td><td>120</td><td>$150/hr</td><td>$18,000</td></tr>
        <tr><td>Frontend Development</td><td>80</td><td>$140/hr</td><td>$11,200</td></tr>
        <tr><td>UI/UX Design</td><td>40</td><td>$130/hr</td><td>$5,200</td></tr>
        <tr><td>Project Management</td><td>30</td><td>$120/hr</td><td>$3,600</td></tr>
        <tr><td><strong>Total</strong></td><td></td><td></td><td><strong>{{ amount }}</strong></td></tr>
      </tbody>
    </table>

    <h2>4. Terms and Conditions</h2>
    <p>Payment is due within {{ payment_terms }} days of invoice date. Late payments are subject to 1.5% monthly interest.</p>
    <p>Either party may terminate this agreement with 30 days written notice.</p>
    <p>All intellectual property created during this engagement shall be transferred to the Client upon full payment.</p>

    <h2>5. Signatures</h2>
    <p>___________________________<br>{{ signer_name }}, {{ signer_title }}<br>{{ company }}</p>
    <p>___________________________<br>{{ client_signer }}, VP Operations<br>{{ client_name }}</p>
    """
  end
end
