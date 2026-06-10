defmodule PhoenixKitDocumentCreator.Documents.PresetManagementTest do
  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.{Template, TemplatePreset}

  defp insert_template!(status) do
    unique = System.unique_integer([:positive])

    {:ok, template} =
      %Template{}
      |> Template.changeset(%{
        name: "Template #{unique}",
        google_doc_id: "tmpl-#{unique}",
        status: status
      })
      |> Repo.insert()

    template
  end

  defp insert_preset!(attrs) do
    base = %{name: "Preset", created_by_uuid: Ecto.UUID.generate()}
    {:ok, preset} = Documents.save_preset(Map.merge(base, attrs))
    preset
  end

  describe "update_preset/2" do
    test "updates name, description and sections" do
      preset = insert_preset!(%{name: "Old", scope_id: Ecto.UUID.generate()})

      assert {:ok, updated} =
               Documents.update_preset(preset, %{
                 name: "New",
                 description: "Desc",
                 sections: [%{"template_uuid" => nil, "position" => 0}]
               })

      assert updated.name == "New"
      assert updated.description == "Desc"
      assert length(updated.sections) == 1
    end

    test "returns error changeset for blank name" do
      preset = insert_preset!(%{name: "Old"})
      assert {:error, %Ecto.Changeset{}} = Documents.update_preset(preset, %{name: ""})
    end
  end

  describe "delete_preset/1" do
    test "removes the preset" do
      preset = insert_preset!(%{name: "Doomed"})
      assert {:ok, _} = Documents.delete_preset(preset)
      assert Repo.get(TemplatePreset, preset.uuid) == nil
    end
  end

  describe "preset_stale_info/1" do
    test "flags sections with missing or trashed templates" do
      ok = insert_template!("published")
      trashed = insert_template!("trashed")
      missing_uuid = Ecto.UUID.generate()

      preset =
        insert_preset!(%{
          sections: [
            %{"template_uuid" => ok.uuid, "position" => 0},
            %{"template_uuid" => trashed.uuid, "position" => 1},
            %{"template_uuid" => missing_uuid, "position" => 2}
          ]
        })

      info = Documents.preset_stale_info(preset)

      assert info.broken_count == 2

      assert MapSet.new(info.broken_template_uuids) ==
               MapSet.new([trashed.uuid, missing_uuid])
    end

    test "reports zero for an all-published preset" do
      ok = insert_template!("published")
      preset = insert_preset!(%{sections: [%{"template_uuid" => ok.uuid, "position" => 0}]})

      assert Documents.preset_stale_info(preset).broken_count == 0
    end
  end
end
