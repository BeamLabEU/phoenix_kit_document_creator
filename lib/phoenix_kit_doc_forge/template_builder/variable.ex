defmodule PhoenixKitDocForge.TemplateBuilder.Variable do
  @moduledoc """
  Variable definitions for document templates.

  Variables are placeholders in template text that get substituted with actual
  values when generating a PDF. Uses Liquid/Solid syntax: `{{ variable_name }}`.
  """

  alias PhoenixKitDocForge.TemplateBuilder.Block

  @type variable_type :: :text | :date | :currency | :multiline

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          type: variable_type(),
          default: String.t() | nil,
          required: boolean()
        }

  @enforce_keys [:name, :label, :type]
  defstruct [:name, :label, :type, default: nil, required: false]

  @doc """
  Extracts variable names from a list of blocks by scanning all text content
  for `{{ variable_name }}` patterns.

  Returns a list of unique variable names (strings).
  """
  def extract_from_blocks(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(&extract_from_block/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Extracts variable names from header and footer HTML strings.
  """
  def extract_from_html(html) when is_binary(html) do
    extract_variable_names(html)
  end

  def extract_from_html(_), do: []

  @doc """
  Extracts all variables from blocks, header, and footer, returning unique sorted names.
  """
  def extract_all(blocks, header_html \\ "", footer_html \\ "") do
    block_vars = extract_from_blocks(blocks)
    header_vars = extract_from_html(header_html)
    footer_vars = extract_from_html(footer_html)

    (block_vars ++ header_vars ++ footer_vars)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Builds Variable structs from a list of variable names, guessing types from names.
  """
  def build_definitions(names) when is_list(names) do
    Enum.map(names, fn name ->
      %__MODULE__{
        name: name,
        label: humanize(name),
        type: guess_type(name),
        required: name in ~w(company client_name),
        default: nil
      }
    end)
  end

  @doc "Returns default variable values for the sample contract."
  def default_values do
    %{
      "company" => "Acme Development LLC",
      "client_name" => "Widget Corp International",
      "contract_date" => "March 1, 2026",
      "amount" => "$38,000",
      "description" =>
        "The Provider agrees to deliver comprehensive software development services including backend API development, frontend web application, UI/UX design, and project management."
    }
  end

  # --- Private ---

  defp extract_from_block(%Block{type: :heading, content: %{text: text}}),
    do: extract_variable_names(text)

  defp extract_from_block(%Block{type: :paragraph, content: %{text: text}}),
    do: extract_variable_names(text)

  defp extract_from_block(%Block{type: :table, content: %{columns: cols, rows: rows}}) do
    all_text = List.flatten([cols | rows])
    Enum.flat_map(all_text, &extract_variable_names/1)
  end

  defp extract_from_block(%Block{type: :list, content: %{items: items}}) do
    Enum.flat_map(items, &extract_variable_names/1)
  end

  defp extract_from_block(%Block{type: :signature, content: %{labels: labels}}) do
    Enum.flat_map(labels, &extract_variable_names/1)
  end

  defp extract_from_block(_block), do: []

  defp extract_variable_names(text) when is_binary(text) do
    ~r/\{\{\s*(\w+)\s*\}\}/
    |> Regex.scan(text)
    |> Enum.map(fn [_full, name] -> name end)
  end

  defp extract_variable_names(_), do: []

  defp humanize(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp guess_type(name) do
    cond do
      String.contains?(name, "date") -> :date
      String.contains?(name, "amount") or String.contains?(name, "price") -> :currency
      String.contains?(name, "description") or String.contains?(name, "notes") -> :multiline
      true -> :text
    end
  end
end
