defmodule PhoenixKitDocumentCreator.Test.SchemaMigration do
  @moduledoc """
  Test-boot wrapper around the module-owned migration chain (the
  projects-repo pattern): `test_helper.exs` runs this through
  `Ecto.Migrator` keyed on `current_version/0`, so a chain bump
  re-applies automatically.
  """

  use Ecto.Migration

  alias PhoenixKitDocumentCreator.Migrations.Schema

  def up, do: Schema.up(prefix: "public")
  def down, do: Schema.down(prefix: "public")
end
