# Test helper for PhoenixKitDocumentCreator test suite
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests require PostgreSQL — automatically excluded
#          when the database is unavailable.
#
# To enable integration tests:
#   createdb phoenix_kit_document_creator_test

alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo

# Check if the test database exists before trying to connect
db_config = Application.get_env(:phoenix_kit_document_creator, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_document_creator_test"

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` not on PATH (sandboxes, CI images without the client) —
    # fall through to the connect attempt instead of crashing the suite.
    ErlangError -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n  Test database "#{db_name}" not found — integration tests excluded.
       Run: createdb #{db_name}
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Enable uuid-ossp + pgcrypto extensions. pgcrypto provides
      # `gen_random_bytes()` which `uuid_generate_v7()` calls below;
      # without it any insert into a table that defaults its uuid column
      # to `uuid_generate_v7()` raises `function gen_random_bytes does
      # not exist`.
      TestRepo.query!("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")
      TestRepo.query!("CREATE EXTENSION IF NOT EXISTS pgcrypto")

      # Create uuid_generate_v7() function (normally created by PhoenixKit V40 migration)
      TestRepo.query!("""
      CREATE OR REPLACE FUNCTION uuid_generate_v7()
      RETURNS uuid AS $$
      DECLARE
        unix_ts_ms bytea;
        uuid_bytes bytea;
      BEGIN
        unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
        uuid_bytes := unix_ts_ms || gen_random_bytes(10);
        uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);
        uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);
        RETURN encode(uuid_bytes, 'hex')::uuid;
      END;
      $$ LANGUAGE plpgsql VOLATILE;
      """)

      # Run test migration to create tables (production uses PhoenixKit V86)
      Ecto.Migrator.up(TestRepo, 0, PhoenixKitDocumentCreator.Test.Migration, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.
           Run: createdb #{db_name}
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.
           Run: createdb #{db_name}
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_document_creator, :test_repo_available, repo_available)

# Pin `PhoenixKit.Config.url_prefix/0` to "/" via :persistent_term so
# tests that boot before any settings read get a stable value (the LV
# routes use `Routes.path/1`, which reads this).
:persistent_term.put(:phoenix_kit_url_prefix, "/")

# Start minimal PhoenixKit services needed for tests
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# `Documents.fetch_thumbnails_async/2` and other async paths spawn
# children under `PhoenixKit.TaskSupervisor`. Without it started in
# the test VM, those paths fail with `:noproc` exits during LV tests.
case Task.Supervisor.start_link(name: PhoenixKit.TaskSupervisor) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# Start the LiveView test endpoint (used by LV smoke tests). The
# endpoint depends on PubSub, so spin that up first if it isn't already
# running.
{:ok, _} = Application.ensure_all_started(:phoenix)
{:ok, _} = Application.ensure_all_started(:phoenix_live_view)
{:ok, _} = PhoenixKitDocumentCreator.Test.Endpoint.start_link()

# `PhoenixKit.PubSubHelper.broadcast/2` derives its PubSub server from the
# host app's config; tests run without a parent app, so start the fallback
# `PhoenixKit.PubSub` registry to exercise broadcast paths (e.g. the
# `Documents.register_existing_document/2` pubsub option).
case Supervisor.start_link(
       [{Phoenix.PubSub, name: PhoenixKit.PubSub}],
       strategy: :one_for_one,
       name: PhoenixKitDocumentCreator.Test.PubSubSupervisor
     ) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
  {:error, reason} -> raise "PubSub test supervisor failed to start: #{inspect(reason)}"
end

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
