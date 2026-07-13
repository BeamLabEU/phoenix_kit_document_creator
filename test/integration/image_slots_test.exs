if Code.ensure_loaded?(PhoenixKitDocumentCreator.DataCase) do
  defmodule PhoenixKitDocumentCreator.Integration.ImageSlotsTest do
    use PhoenixKitDocumentCreator.DataCase, async: false

    alias PhoenixKitDocumentCreator.Documents

    defmodule StubDocsClient do
      def get_document_text(doc_id) do
        case Process.get({:stub_doc_text, doc_id}) do
          nil -> {:error, :not_found}
          text -> {:ok, text}
        end
      end
    end

    setup do
      prev = Application.get_env(:phoenix_kit_document_creator, :docs_client)
      Application.put_env(:phoenix_kit_document_creator, :docs_client, StubDocsClient)

      on_exit(fn ->
        if prev do
          Application.put_env(:phoenix_kit_document_creator, :docs_client, prev)
        else
          Application.delete_env(:phoenix_kit_document_creator, :docs_client)
        end
      end)

      :ok
    end

    defp insert_template_with_doc_text!(text) do
      unique = System.unique_integer([:positive])
      doc_id = "stub-doc-#{unique}"
      Process.put({:stub_doc_text, doc_id}, text)

      # Mirror `Documents.detect_variables/1`: cache the detected variable
      # definitions on the row, as the template picker does before any
      # variable-config edit happens in the real flow.
      # `update_template_variable_config/3` intentionally rejects variables
      # missing from the DB cache with `:unknown_variable`.
      var_defs =
        text
        |> PhoenixKitDocumentCreator.Variable.extract_variables()
        |> PhoenixKitDocumentCreator.Variable.build_definitions()
        |> Enum.map(&Map.from_struct/1)

      {:ok, template} =
        Documents.upsert_template_from_drive(
          %{"id" => doc_id, "name" => "Test #{unique}"},
          %{variables: var_defs}
        )

      template
    end

    describe "image_slots_for_template/1" do
      test "returns {:ok, slots} with image and image_list kinds" do
        template =
          insert_template_with_doc_text!("""
            Hello {{ name }}.
            Logo: {{ image: logo }}
            Gallery: {{ images: photos }}
          """)

        assert {:ok, slots} = Documents.image_slots_for_template(template.uuid)

        # Slots now expose the resolved variable config alongside name/kind.
        assert slots
               |> Enum.sort_by(& &1.name)
               |> Enum.map(&Map.take(&1, [:name, :kind])) == [
                 %{name: "logo", kind: :image},
                 %{name: "photos", kind: :image_list}
               ]

        # image_list slots carry the column config (default 1) consumed by the
        # multi-column Google Docs renderer.
        photos = Enum.find(slots, &(&1.name == "photos"))
        assert photos.config["columns"] == 1

        # Both slot kinds default to annotated true.
        assert photos.config["annotated"] == true
        logo = Enum.find(slots, &(&1.name == "logo"))
        assert logo.config["annotated"] == true
      end

      test "surfaces saved annotated false" do
        template =
          insert_template_with_doc_text!("""
            Logo: {{ image: logo }}
          """)

        assert {:ok, _} =
                 Documents.update_template_variable_config(
                   template.google_doc_id,
                   "logo",
                   %{"annotated" => "false"}
                 )

        assert {:ok, slots} = Documents.image_slots_for_template(template.uuid)
        logo = Enum.find(slots, &(&1.name == "logo"))
        assert logo.config["annotated"] == false
      end

      test "returns {:error, :not_found} for unknown template uuid" do
        assert {:error, :not_found} =
                 Documents.image_slots_for_template(Ecto.UUID.generate())
      end

      test "returns empty list when template has no image tags" do
        template = insert_template_with_doc_text!("Hello {{ name }}. No images here.")

        assert {:ok, []} = Documents.image_slots_for_template(template.uuid)
      end
    end
  end
end
