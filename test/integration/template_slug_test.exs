defmodule PhoenixKitDocumentCreator.Integration.TemplateSlugTest do
  @moduledoc """
  Slug generation for `Schemas.Template` after adopting core's
  `PhoenixKit.Utils.Slug.put_slug/3`.

  These live here rather than in the async unit file because `put_slug/3`
  probes the repo for collisions and `config/test.exs` wires one, so every
  generating changeset needs a sandbox owner. The paths that return before
  the probe — explicit slug, record already slugged — stay in
  `test/schemas/template_test.exs`.

  Exact transliteration output is deliberately not pinned (one ASCII case
  aside): what core returns depends on which `phoenix_kit` resolves, and
  asserting version-dependent romanization is how phoenix_kit_dashboards#5
  merged red. Shape assertions hold at every core version.
  """
  use PhoenixKitDocumentCreator.DataCase, async: true

  alias Ecto.Changeset
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitDocumentCreator.Schemas.Template

  defp changeset(attrs, template \\ %Template{}), do: Template.changeset(template, attrs)
  defp insert!(attrs), do: attrs |> changeset() |> Repo.insert!()

  describe "generation" do
    test "derives the slug from the name" do
      assert changeset(%{name: "My Great Template"}) |> Changeset.get_change(:slug) ==
               "my-great-template"
    end

    test "romanizes a Cyrillic name instead of emptying it" do
      slug = changeset(%{name: "Договор оказания услуг"}) |> Changeset.get_change(:slug)

      assert is_binary(slug) and slug != ""
      assert slug =~ ~r/^[a-z0-9-]+$/
    end

    test "writes nothing when the name has no romanizable content" do
      # Core's slugify falls back to "" for unromanizable scripts, and
      # put_slug then leaves the changeset alone rather than storing a blank
      # for the next save to fight over.
      assert changeset(%{name: "日本語"}) |> Changeset.get_change(:slug) == nil
    end
  end

  describe "uniqueness" do
    test "suffixes -2 when the slug is taken" do
      insert!(%{name: "Service Agreement"})

      assert changeset(%{name: "Service Agreement"}) |> Changeset.get_change(:slug) ==
               "service-agreement-2"
    end

    test "the suffix stays inside varchar(255)" do
      name = String.duplicate("a", 255)
      insert!(%{name: name})

      slug = changeset(%{name: name}) |> Changeset.get_change(:slug)

      assert String.ends_with?(slug, "-2")
      assert String.length(slug) == 255
    end

    test "blanking the slug through cast is a no-op, not a regeneration" do
      # `cast/3` treats "" as an empty value and drops it, so no change ever
      # reaches put_slug — the record keeps its slug. The blank-regenerate
      # branch is only reachable through `change/2`, below.
      template = insert!(%{name: "Original Name"})
      cs = changeset(%{slug: ""}, template)

      assert Changeset.get_change(cs, :slug) == nil
      assert Changeset.get_field(cs, :slug) == "original-name"
    end

    test "a blanked slug set via change/2 regenerates from the name" do
      # A hand-picked slug, distinct from what the name generates — otherwise
      # `put_change/3` drops a regenerated value equal to the data and there
      # is no change to observe.
      template = insert!(%{name: "Original Name", slug: "hand-picked"})

      cs =
        template
        |> Changeset.change(%{slug: ""})
        |> Slug.put_slug(:name, max_length: 255)

      # No other row holds "original-name", so no suffix — and the probe
      # excluded this row itself while checking.
      assert Changeset.get_change(cs, :slug) == "original-name"
    end
  end
end
