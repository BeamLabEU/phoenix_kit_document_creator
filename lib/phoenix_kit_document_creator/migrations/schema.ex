defmodule PhoenixKitDocumentCreator.Migrations.Schema do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_document_creator` —
  the decentralized-migrations protocol core's `mix phoenix_kit.update`
  discovers via `migration_module/0` (`current_version/0` +
  `migrated_version_runtime/1` + idempotent `up/1` + version-aware
  `down/1`). Adopted per the workspace direction of moving module tables
  out of the core chain (`phoenix_kit_projects` is the reference
  implementation; the doc TABLES themselves remain core-created — V86 +
  V94 — this chain only ITERATES on them).

  Versions:

    * **V1** — `phoenix_kit_doc_documents.project_uuid` (nullable FK →
      `phoenix_kit_projects`, ON DELETE SET NULL): real per-project
      document linkage for the projects hub's Documents tab. The FK
      target is core-created (V101), present on every current install.

  The migrated version is tracked as a `dcr_schema:<N>` COMMENT on
  `phoenix_kit_doc_documents` (the marker convention from the projects
  chain, namespaced). A marker-less table reads as version 0 — the core
  baseline shape before this chain existed.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "dcr_schema:"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `dcr_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — unlike the
  projects chain there is no pre-chain content to defend, V1 is purely
  additive).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # classoid anchors the description join to pg_class (the projects
    # chain's ZAI panel find R1-4).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = 'phoenix_kit_doc_documents' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  @doc "Applies every chain version up to `current_version/0` (idempotent)."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)
    p = prefix_str(prefix)

    v1_project_link(p)

    execute(
      "COMMENT ON TABLE #{p}phoenix_kit_doc_documents IS '#{@marker_prefix}#{@current_version}'"
    )
  end

  @doc "Rolls back to `target` (version-aware; 0 removes everything this chain added)."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    p = prefix_str(prefix)
    target = Keyword.get(opts, :version, 0)

    if target < 1 do
      execute("ALTER TABLE #{p}phoenix_kit_doc_documents DROP COLUMN IF EXISTS project_uuid")
    end

    if target > 0 do
      execute("COMMENT ON TABLE #{p}phoenix_kit_doc_documents IS '#{@marker_prefix}#{target}'")
    else
      execute("COMMENT ON TABLE #{p}phoenix_kit_doc_documents IS NULL")
    end
  end

  defp v1_project_link(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_doc_documents
    ADD COLUMN IF NOT EXISTS project_uuid UUID
      REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE SET NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_doc_documents_project_index
    ON #{p}phoenix_kit_doc_documents (project_uuid)
    """)
  end

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL — same guard the projects chain uses.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end

  defp prefix_str(prefix), do: "#{prefix}."
end
