defmodule PhoenixKitDocumentCreator.Variable do
  @moduledoc """
  Variable definitions for document templates.

  Variables are placeholders in template text that get substituted with actual
  values when generating a PDF. Uses Liquid/Solid syntax: `{{ variable_name }}`.
  """

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
  Extracts variable names from an HTML string by scanning for
  `{{ variable_name }}` patterns.

  Returns a sorted list of unique variable names (strings).
  """
  def extract_from_html(html) when is_binary(html) do
    ~r/\{\{\s*(\w+)\s*\}\}/
    |> Regex.scan(html)
    |> Enum.map(fn [_full, name] -> name end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def extract_from_html(_), do: []

  @doc """
  Builds Variable structs from a list of variable names, guessing types from names.
  """
  def build_definitions(names) when is_list(names) do
    Enum.map(names, fn name ->
      %__MODULE__{
        name: name,
        label: humanize(name),
        type: guess_type(name),
        required: false,
        default: nil
      }
    end)
  end

  @doc "Converts an underscore_name to a human-readable label."
  def humanize(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  @doc "Guesses the variable type from its name."
  def guess_type(name) do
    cond do
      String.contains?(name, "date") -> :date
      String.contains?(name, "amount") or String.contains?(name, "price") -> :currency
      String.contains?(name, "description") or String.contains?(name, "notes") -> :multiline
      true -> :text
    end
  end
end
