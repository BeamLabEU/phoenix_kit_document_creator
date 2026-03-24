defmodule Mix.Tasks.PhoenixKitDocumentCreator.Install do
  @moduledoc """
  Installs PhoenixKitDocumentCreator (Document Creator) into the parent application.

      mix phoenix_kit_document_creator.install

  Database tables are managed by PhoenixKit core migrations (V86).
  Run `mix phoenix_kit.update` followed by `mix ecto.migrate` to create tables.
  JS hooks and vendor assets are loaded automatically by PhoenixKit —
  no parent app.js changes needed.
  """
  use Mix.Task

  @shortdoc "Installs Document Creator"

  @impl Mix.Task
  def run(_args) do
    clean_legacy_js()

    Mix.shell().info("""
    \nInstallation complete!
    - Tables are created by PhoenixKit core migrations (V86).
    - Run `mix phoenix_kit.update` then `mix ecto.migrate` if tables don't exist yet.
    - JS hooks load automatically via PhoenixKit — no app.js changes needed.
    """)
  end

  # ── Legacy cleanup ───────────────────────────────────────────────

  # Remove old JS integration from app.js if it exists (from pre-auto-load versions)
  defp clean_legacy_js do
    js_path = "assets/js/app.js"

    if File.exists?(js_path) do
      content = File.read!(js_path)

      markers = [
        "// PhoenixKitDocForge JS - DO NOT REMOVE",
        "// Document Creator JS - DO NOT REMOVE",
        "// PhoenixKitDocumentCreator JS - DO NOT REMOVE"
      ]

      if Enum.any?(markers, &String.contains?(content, &1)) do
        updated =
          content
          |> String.replace(
            ~r/\n?\/\/ (PhoenixKitDoc\w+|Document Creator) JS - DO NOT REMOVE\n/,
            "\n"
          )
          |> String.replace(
            ~r/import "[^"]*phoenix_kit_doc(ument_creator|_forge)[^"]*"\n?/,
            ""
          )
          |> String.replace(~r/\n{3,}/, "\n\n")

        File.write!(js_path, updated)
        Mix.shell().info("Cleaned up legacy JS import from #{js_path}")
      end
    end
  end
end
