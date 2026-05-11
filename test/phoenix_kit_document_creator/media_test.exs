defmodule PhoenixKitDocumentCreator.MediaTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Media

  defmodule StubStorage do
    def get_file("known-uuid"),
      do: %{uuid: "known-uuid", width: 1200, height: 800, file_type: "image"}

    def get_file("no-dims-uuid"),
      do: %{uuid: "no-dims-uuid", width: nil, height: nil, file_type: "image"}

    def get_file("http-uuid"),
      do: %{uuid: "http-uuid", width: 100, height: 100}

    def get_file("long-url-uuid"),
      do: %{uuid: "long-url-uuid", width: 100, height: 100}

    def get_file(_), do: nil

    def get_public_url(%{uuid: "known-uuid"}), do: "https://cdn.example.com/image.jpg"
    def get_public_url(%{uuid: "no-dims-uuid"}), do: "https://cdn.example.com/nodims.jpg"
    def get_public_url(%{uuid: "http-uuid"}), do: "http://cdn.example.com/image.jpg"

    def get_public_url(%{uuid: "long-url-uuid"}),
      do: "https://" <> String.duplicate("a", 2049)

    def get_public_url(_), do: nil
  end

  setup do
    Application.put_env(:phoenix_kit_document_creator, :media_module, StubStorage)
    on_exit(fn -> Application.delete_env(:phoenix_kit_document_creator, :media_module) end)
    :ok
  end

  describe "get_url_and_dimensions/1" do
    test "returns uri, width, and height for a known media_id" do
      assert {:ok, %{uri: uri, width_px: 1200, height_px: 800}} =
               Media.get_url_and_dimensions("known-uuid")

      assert uri == "https://cdn.example.com/image.jpg"
    end

    test "returns :image_not_found when media_id does not exist" do
      assert {:error, :image_not_found} = Media.get_url_and_dimensions("missing-uuid")
    end

    test "returns :image_url_not_public when the file has no public URL" do
      defmodule NoUrlStorage do
        def get_file("uuid"), do: %{uuid: "uuid", width: 100, height: 100}
        def get_public_url(_), do: nil
      end

      Application.put_env(:phoenix_kit_document_creator, :media_module, NoUrlStorage)
      assert {:error, :image_url_not_public} = Media.get_url_and_dimensions("uuid")
    end

    test "returns nil width_px and height_px when dimensions are not stored" do
      assert {:ok, %{uri: _, width_px: nil, height_px: nil}} =
               Media.get_url_and_dimensions("no-dims-uuid")
    end

    test "returns :image_url_not_public for non-https URL" do
      assert {:error, :image_url_not_public} = Media.get_url_and_dimensions("http-uuid")
    end

    test "returns :image_url_not_public for URL longer than 2048 bytes" do
      assert {:error, :image_url_not_public} = Media.get_url_and_dimensions("long-url-uuid")
    end
  end
end
