defmodule Mix.Tasks.PhoenixKitDocumentCreator.Install do
  @moduledoc """
  Installs PhoenixKitDocumentCreator (Document Creator) into the parent application.

      mix phoenix_kit_document_creator.install

  This task creates a database migration for the document creator tables.
  JS hooks and vendor assets are loaded automatically by PhoenixKit —
  no parent app.js changes needed.
  """
  use Mix.Task

  @shortdoc "Installs Document Creator (creates migration)"

  @impl Mix.Task
  def run(_args) do
    create_migration()
    clean_legacy_js()

    Mix.shell().info("""
    \nInstallation complete!
    - Run `mix ecto.migrate` to create the tables.
    - JS hooks load automatically via PhoenixKit — no app.js changes needed.
    """)
  end

  # ── Migration ─────────────────────────────────────────────────────

  defp create_migration do
    app_name = Mix.Project.config()[:app]
    app_module = app_name |> to_string() |> Macro.camelize()
    migrations_dir = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_dir)

    existing =
      migrations_dir
      |> File.ls!()
      |> Enum.find(fn name ->
        String.contains?(name, "add_document_creator_tables") or
          String.contains?(name, "add_doc_forge_tables")
      end)

    if existing do
      Mix.shell().info("Migration already exists: #{existing}")
    else
      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      filename = "#{timestamp}_add_document_creator_tables.exs"
      path = Path.join(migrations_dir, filename)

      content = """
      defmodule #{app_module}.Repo.Migrations.AddDocumentCreatorTables do
        use Ecto.Migration

        def up, do: PhoenixKitDocumentCreator.Migration.up()
        def down, do: PhoenixKitDocumentCreator.Migration.down()
      end
      """

      File.write!(path, content)
      Mix.shell().info("Created migration: #{path}")
    end
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
