defmodule PhoenixKitDocumentCreator.Integration.ActiveIntegrationTest do
  @moduledoc """
  Tests `GoogleDocsClient.active_integration_uuid/0` and the legacy
  auto-migration flow that converts old `"google"` / `"google:name"`
  settings values to integration uuids on first read.

  Uses DataCase for settings + the StubIntegrations backend for
  Integrations dispatch.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Test.StubIntegrations

  @settings_key "document_creator_settings"

  setup do
    previous = Application.get_env(:phoenix_kit_document_creator, :integrations_backend)

    Application.put_env(
      :phoenix_kit_document_creator,
      :integrations_backend,
      StubIntegrations
    )

    StubIntegrations.reset!()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
        else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)

      StubIntegrations.reset!()

      Settings.update_json_setting_with_module(@settings_key, %{}, "document_creator")
    end)

    :ok
  end

  defp set_connection_setting(value) do
    current = Settings.get_json_setting(@settings_key, %{})
    updated = Map.put(current, "google_connection", value)
    Settings.update_json_setting_with_module(@settings_key, updated, "document_creator")
  end

  defp clear_connection_setting do
    Settings.update_json_setting_with_module(@settings_key, %{}, "document_creator")
  end

  describe "active_integration_uuid/0" do
    test "returns nil when no setting is stored" do
      clear_connection_setting()
      assert GoogleDocsClient.active_integration_uuid() == nil
    end

    test "returns the uuid as-is when already in the modern shape" do
      uuid = "019d0000-0000-7000-8000-000000000001"
      set_connection_setting(uuid)

      assert GoogleDocsClient.active_integration_uuid() == uuid
    end
  end

  describe "active_integration_uuid/0 — legacy auto-migration" do
    test ~s|legacy "google:name" — exact match resolves to the row's uuid + persists| do
      uuid = "019d0000-0000-7000-8000-000000000002"

      StubIntegrations.connected!("test@example.com")

      StubIntegrations.seed_connection!("google", %{
        uuid: uuid,
        name: "personal",
        data: %{"name" => "personal", "provider" => "google"}
      })

      set_connection_setting("google:personal")

      # First read auto-migrates and returns the uuid.
      assert GoogleDocsClient.active_integration_uuid() == uuid

      # The setting was rewritten in place.
      assert %{"google_connection" => ^uuid} = Settings.get_json_setting(@settings_key, %{})

      # Second read is a direct passthrough (no migration logic re-runs).
      assert GoogleDocsClient.active_integration_uuid() == uuid
    end

    test ~s|legacy bare "google" — falls back to the first available connection| do
      uuid = "019d0000-0000-7000-8000-000000000003"

      StubIntegrations.seed_connection!("google", %{
        uuid: uuid,
        name: "default",
        data: %{"name" => "default", "provider" => "google"}
      })

      set_connection_setting("google")

      # `migrate_legacy_connection/1` first tries
      # `get_integration("google:default")` which the stub doesn't
      # answer (it's keyed off connected_email, not specific keys),
      # so it falls through to the `list_connections/1` first-row
      # path and persists that uuid.
      assert GoogleDocsClient.active_integration_uuid() == uuid

      assert %{"google_connection" => ^uuid} = Settings.get_json_setting(@settings_key, %{})
    end

    test "legacy value with no resolvable target → nil + setting cleared" do
      # No connections seeded; the stub returns empty list_connections.
      set_connection_setting("google:ghost")

      assert GoogleDocsClient.active_integration_uuid() == nil

      # Setting was cleared so subsequent calls don't re-attempt the
      # migration on every page load.
      refute Map.has_key?(Settings.get_json_setting(@settings_key, %{}), "google_connection")
    end
  end

  describe "get_credentials/0" do
    test "returns :not_configured when no integration is picked" do
      clear_connection_setting()
      assert {:error, :not_configured} = GoogleDocsClient.get_credentials()
    end

    test "dispatches to the backend with the active uuid" do
      uuid = "019d0000-0000-7000-8000-000000000010"
      set_connection_setting(uuid)
      StubIntegrations.connected!()

      assert {:ok, %{access_token: "stub-token"}} = GoogleDocsClient.get_credentials()
    end
  end

  describe "connection_status/0" do
    test "returns :not_configured when no integration is picked" do
      clear_connection_setting()
      assert {:error, :not_configured} = GoogleDocsClient.connection_status()
    end

    test "extracts the connected email from the integration metadata" do
      uuid = "019d0000-0000-7000-8000-000000000020"
      set_connection_setting(uuid)
      StubIntegrations.connected!("user@example.com")

      assert {:ok, %{email: "user@example.com"}} = GoogleDocsClient.connection_status()
    end

    test "returns the backend's error tuple unchanged when not connected" do
      uuid = "019d0000-0000-7000-8000-000000000021"
      set_connection_setting(uuid)
      StubIntegrations.disconnected!()

      assert {:error, :not_configured} = GoogleDocsClient.connection_status()
    end
  end

  describe "authenticated_request/3" do
    test "returns :not_configured when no integration is picked" do
      clear_connection_setting()
      assert {:error, :not_configured} = GoogleDocsClient.authenticated_request(:get, "/foo")
    end

    test "forwards through the backend's stub when connected" do
      uuid = "019d0000-0000-7000-8000-000000000030"
      set_connection_setting(uuid)
      StubIntegrations.connected!()

      StubIntegrations.stub_request(:get, "drive/v3/files", {:ok, %{status: 200, body: %{}}})

      assert {:ok, %{status: 200}} =
               GoogleDocsClient.authenticated_request(:get, "https://www.googleapis.com/drive/v3/files")
    end
  end
end
