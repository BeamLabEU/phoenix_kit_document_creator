defmodule PhoenixKitDocumentCreator.Test.ProjectsMigration do
  @moduledoc """
  Test-boot wrapper around Projects' migration chain (a test-only dependency),
  run through `Ecto.Migrator` like `SchemaMigration` runs this module's own.
  """

  use Ecto.Migration

  def up, do: PhoenixKitProjects.Migrations.Schema.up(prefix: "public")
  def down, do: :ok
end
