defmodule PhoenixKitDocumentCreator.GoogleDocsClientTableTest do
  use ExUnit.Case, async: true
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  describe "table_image_inserts/3 — phase A (table creation)" do
    test "returns a deleteContentRange + insertTable for placeholder range" do
      placeholder = %{start_index: 100, end_index: 120}
      media = [%{uri: "u1"}, %{uri: "u2"}, %{uri: "u3"}]
      opts = %{columns: 2, content_width_pt: 468.0}

      reqs = GoogleDocsClient.table_image_inserts(placeholder, media, opts)

      assert [
               %{"deleteContentRange" => %{"range" => %{"startIndex" => 100, "endIndex" => 120}}},
               %{"insertTable" => %{"rows" => 2, "columns" => 2, "location" => %{"index" => 100}}}
             ] = reqs
    end

    test "rows = ceil(count / columns)" do
      placeholder = %{start_index: 0, end_index: 10}
      media = List.duplicate(%{uri: "u"}, 5)
      opts = %{columns: 2, content_width_pt: 468.0}

      reqs = GoogleDocsClient.table_image_inserts(placeholder, media, opts)

      assert Enum.any?(
               reqs,
               &match?(
                 %{"insertTable" => %{"rows" => 3, "columns" => 2}},
                 &1
               )
             )
    end

    test "clamps columns to 1..4" do
      placeholder = %{start_index: 0, end_index: 10}
      media = [%{uri: "u"}]

      reqs =
        GoogleDocsClient.table_image_inserts(placeholder, media, %{
          columns: 99,
          content_width_pt: 468.0
        })

      assert Enum.any?(reqs, &match?(%{"insertTable" => %{"columns" => 4}}, &1))
    end
  end

  describe "fill_table_cells/3 — phase B (image insertion into cells)" do
    test "inserts one image per cell, left-to-right top-to-bottom" do
      # Mock the doc-after-table-creation: cells with known startIndices.
      # Each cell has a paragraph startIndex we insert into.
      cells = [
        %{insert_index: 200},
        %{insert_index: 220},
        %{insert_index: 240},
        %{insert_index: 260}
      ]

      media = [%{uri: "a"}, %{uri: "b"}, %{uri: "c"}]
      opts = %{image_width_pt: 230.0}

      reqs = GoogleDocsClient.fill_table_cells(cells, media, opts)

      uris = for %{"insertInlineImage" => %{"uri" => u}} <- reqs, do: u
      assert uris == ["c", "b", "a"], "insert last-first to avoid index drift"

      indices =
        for %{"insertInlineImage" => %{"location" => %{"index" => i}}} <-
              reqs,
            do: i

      # last-first by original cell order
      assert indices == [240, 220, 200]
    end

    test "ignores extra cells when media is shorter" do
      cells = [
        %{insert_index: 200},
        %{insert_index: 220},
        %{insert_index: 240},
        %{insert_index: 260}
      ]

      media = [%{uri: "a"}]
      reqs = GoogleDocsClient.fill_table_cells(cells, media, %{image_width_pt: 230.0})
      assert length(reqs) == 1
    end

    test "objectSize uses provided image_width_pt for width magnitude" do
      cells = [%{insert_index: 100}]
      media = [%{uri: "a"}]
      [req] = GoogleDocsClient.fill_table_cells(cells, media, %{image_width_pt: 230.0})
      assert get_in(req, ["insertInlineImage", "objectSize", "width", "magnitude"]) == 230.0
    end
  end

  describe "match_new_tables/3 — phase 2 table identification" do
    # Helper: a doc3 table element tagged with an id so we can assert which one
    # was picked. The startIndex models the table's post-Phase-1 position.
    defp table(id, start_index),
      do: %{"id" => id, "table" => %{"startIndex" => start_index}}

    test "no pre-existing tables: every doc3 table is new, in order" do
      tables_asc = [table("a", 110), table("b", 220)]
      # Two slots whose placeholders were at 100 and 200 in doc2.
      assert {:ok, [%{"id" => "a"}, %{"id" => "b"}]} =
               GoogleDocsClient.match_new_tables(tables_asc, [], [100, 200])
    end

    test "pre-existing table BEFORE the placeholders is excluded" do
      # doc2: pre-existing table at 40, slots at 100/200. Pattern [:pre,:new,:new].
      # doc3 (pre-existing at 40 unaffected, new ones shifted): 40, 110, 220.
      tables_asc = [table("pre", 40), table("a", 110), table("b", 220)]

      assert {:ok, [%{"id" => "a"}, %{"id" => "b"}]} =
               GoogleDocsClient.match_new_tables(tables_asc, [40], [100, 200])
    end

    test "pre-existing table AFTER a placeholder is excluded (the drift case)" do
      # doc2: slots at 100/200, pre-existing table at 300. Pattern [:new,:new,:pre].
      # Phase 1 shifts the pre-existing table to 360 in doc3. The old
      # set-difference (300 in snapshot, 360 in doc3) would have flagged it as
      # "new" and tripped the count guard; order-based matching gets it right.
      tables_asc = [table("a", 110), table("b", 210), table("pre", 360)]

      assert {:ok, [%{"id" => "a"}, %{"id" => "b"}]} =
               GoogleDocsClient.match_new_tables(tables_asc, [300], [100, 200])
    end

    test "pre-existing table BETWEEN two placeholders is excluded" do
      # doc2 order: slot@100, pre@150, slot@200 → pattern [:new,:pre,:new].
      tables_asc = [table("a", 110), table("pre", 165), table("b", 230)]

      assert {:ok, [%{"id" => "a"}, %{"id" => "b"}]} =
               GoogleDocsClient.match_new_tables(tables_asc, [150], [100, 200])
    end

    test "count mismatch returns :mismatch so the caller skips Phase 2" do
      # Expected 1 pre-existing + 2 new = 3 tables, but only 2 are present.
      tables_asc = [table("a", 110), table("b", 220)]
      assert :mismatch = GoogleDocsClient.match_new_tables(tables_asc, [40], [100, 200])
    end
  end
end
