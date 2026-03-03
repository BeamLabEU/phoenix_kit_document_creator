defmodule PhoenixKitDocForge.TemplateBuilder.Block do
  @moduledoc """
  Block type definitions and HTML rendering for document templates.

  Each template is composed of an ordered list of blocks. Blocks are rendered
  to HTML, with variable placeholders substituted via Solid (Liquid syntax).
  """

  @type block_type ::
          :heading
          | :paragraph
          | :table
          | :list
          | :signature
          | :divider
          | :spacer
          | :page_break
          | :image_placeholder

  @type t :: %__MODULE__{
          id: String.t(),
          type: block_type(),
          content: map()
        }

  @enforce_keys [:id, :type, :content]
  defstruct [:id, :type, :content]

  @block_types ~w(heading paragraph table list signature divider spacer page_break image_placeholder)a

  def block_types, do: @block_types

  @doc "Creates a new block with a unique ID."
  def new(type, content \\ %{}) when type in @block_types do
    %__MODULE__{
      id: generate_id(),
      type: type,
      content: Map.merge(default_content(type), content)
    }
  end

  @doc "Returns default content for a given block type."
  def default_content(:heading), do: %{level: 1, text: ""}
  def default_content(:paragraph), do: %{text: ""}
  def default_content(:table), do: %{columns: ["Column 1", "Column 2"], rows: [["", ""]]}
  def default_content(:list), do: %{style: :unordered, items: [""]}
  def default_content(:signature), do: %{columns: 2, labels: ["", ""]}
  def default_content(:divider), do: %{style: "solid"}
  def default_content(:spacer), do: %{height: "20px"}
  def default_content(:page_break), do: %{}
  def default_content(:image_placeholder), do: %{label: "Image", width: "150px", height: "50px"}

  @doc "Human-readable label for a block type."
  def type_label(:heading), do: "Heading"
  def type_label(:paragraph), do: "Paragraph"
  def type_label(:table), do: "Table"
  def type_label(:list), do: "List"
  def type_label(:signature), do: "Signature Block"
  def type_label(:divider), do: "Divider"
  def type_label(:spacer), do: "Spacer"
  def type_label(:page_break), do: "Page Break"
  def type_label(:image_placeholder), do: "Image Placeholder"

  @doc "Icon class for a block type."
  def type_icon(:heading), do: "hero-bars-3"
  def type_icon(:paragraph), do: "hero-document-text"
  def type_icon(:table), do: "hero-table-cells"
  def type_icon(:list), do: "hero-list-bullet"
  def type_icon(:signature), do: "hero-pencil"
  def type_icon(:divider), do: "hero-minus"
  def type_icon(:spacer), do: "hero-arrows-up-down"
  def type_icon(:page_break), do: "hero-document-duplicate"
  def type_icon(:image_placeholder), do: "hero-photo"

  @doc "Renders a block to HTML string. Variables are NOT substituted here — that's done by PdfRenderer."
  def render_to_html(%__MODULE__{type: :heading, content: %{level: level, text: text}}) do
    tag = "h#{min(max(level, 1), 6)}"
    "<#{tag}>#{escape(text)}</#{tag}>"
  end

  def render_to_html(%__MODULE__{type: :paragraph, content: %{text: text}}) do
    "<p>#{escape(text)}</p>"
  end

  def render_to_html(%__MODULE__{type: :table, content: %{columns: columns, rows: rows}}) do
    header =
      columns
      |> Enum.map(&"<th>#{escape(&1)}</th>")
      |> Enum.join()

    body =
      rows
      |> Enum.map(fn row ->
        cells = row |> Enum.map(&"<td>#{escape(&1)}</td>") |> Enum.join()
        "<tr>#{cells}</tr>"
      end)
      |> Enum.join()

    """
    <table>
      <thead><tr>#{header}</tr></thead>
      <tbody>#{body}</tbody>
    </table>
    """
  end

  def render_to_html(%__MODULE__{type: :list, content: %{style: style, items: items}}) do
    tag = if style == :ordered, do: "ol", else: "ul"

    items_html =
      items
      |> Enum.map(&"<li>#{escape(&1)}</li>")
      |> Enum.join()

    "<#{tag}>#{items_html}</#{tag}>"
  end

  def render_to_html(%__MODULE__{type: :signature, content: %{columns: columns, labels: labels}}) do
    sigs =
      labels
      |> Enum.take(columns)
      |> Enum.map(fn label ->
        ~s(<div class="signature"><div class="signature-line"></div><p class="signature-name">#{escape(label)}</p></div>)
      end)
      |> Enum.join()

    ~s(<div class="signature-block">#{sigs}</div>)
  end

  def render_to_html(%__MODULE__{type: :divider}) do
    "<hr />"
  end

  def render_to_html(%__MODULE__{type: :spacer, content: %{height: height}}) do
    ~s(<div style="height: #{escape(height)}"></div>)
  end

  def render_to_html(%__MODULE__{type: :page_break}) do
    ~s(<div style="page-break-before: always"></div>)
  end

  def render_to_html(%__MODULE__{
        type: :image_placeholder,
        content: %{label: label, width: w, height: h}
      }) do
    ~s(<div class="image-placeholder" style="width: #{escape(w)}; height: #{escape(h)}; border: 1px dashed #ccc; display: flex; align-items: center; justify-content: center; color: #999; font-size: 10pt;">#{escape(label)}</div>)
  end

  @doc "Returns a sample contract template as a list of blocks."
  def default_blocks do
    [
      new(:heading, %{level: 1, text: "Service Agreement"}),
      new(:paragraph, %{
        text: "Agreement No. SA-2026-0042 — Effective {{ contract_date }}"
      }),
      new(:divider),
      new(:heading, %{level: 2, text: "Parties"}),
      new(:paragraph, %{
        text:
          "This agreement is between {{ company }} (\"Provider\"), located at 123 Innovation Drive, San Francisco, CA 94102, and {{ client_name }} (\"Client\"), located at 456 Business Avenue, New York, NY 10001."
      }),
      new(:heading, %{level: 2, text: "1. Scope of Services"}),
      new(:paragraph, %{
        text: "{{ description }}"
      }),
      new(:heading, %{level: 2, text: "2. Pricing"}),
      new(:table, %{
        columns: ["Service", "Hours", "Rate", "Amount"],
        rows: [
          ["Backend Development", "120", "$150/hr", "$18,000"],
          ["Frontend Development", "80", "$140/hr", "$11,200"],
          ["UI/UX Design", "40", "$130/hr", "$5,200"],
          ["Project Management", "30", "$120/hr", "$3,600"],
          ["Total", "", "", "{{ amount }}"]
        ]
      }),
      new(:heading, %{level: 2, text: "3. Terms and Conditions"}),
      new(:list, %{
        style: :unordered,
        items: [
          "Payment is due within 30 days of invoice date.",
          "Late payments are subject to 1.5% monthly interest.",
          "Either party may terminate with 30 days written notice.",
          "All IP created transfers to Client upon full payment."
        ]
      }),
      new(:spacer, %{height: "40px"}),
      new(:signature, %{
        columns: 2,
        labels: [
          "John Smith, CEO — {{ company }}",
          "Jane Doe, VP Operations — {{ client_name }}"
        ]
      })
    ]
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(other), do: escape(to_string(other))
end
