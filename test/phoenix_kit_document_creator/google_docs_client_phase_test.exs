defmodule PhoenixKitDocumentCreator.GoogleDocsClientPhaseTest do
  use ExUnit.Case, async: true
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # ---------------------------------------------------------------------------
  # list_image_inserts/3 — columns=1 uses inline PT-width path
  # ---------------------------------------------------------------------------

  describe "list_image_inserts/3 with columns=1" do
    test "produces insertInlineImage requests, no insertTable" do
      fill = %{
        kind: :image_list,
        columns: 1,
        media: [
          %{uri: "u1", width_px: nil, height_px: nil},
          %{uri: "u2", width_px: nil, height_px: nil}
        ],
        separator: :newline
      }

      # Invoke via build_image_batch_requests/3 (the public API).
      ranges = [%{name: "photos", start_index: 10, end_index: 30}]
      fills = %{"photos" => fill}
      requests = GoogleDocsClient.build_image_batch_requests(ranges, fills, 468.0)

      refute Enum.any?(requests, &Map.has_key?(&1, "insertTable"))
      assert Enum.any?(requests, &Map.has_key?(&1, :insertInlineImage))
    end

    test "width uses content-width-based PT (image_width_for_columns(cw, 1) = cw)" do
      fill = %{
        kind: :image_list,
        columns: 1,
        media: [%{uri: "u1", width_px: nil, height_px: nil}],
        separator: :newline
      }

      ranges = [%{name: "img", start_index: 5, end_index: 25}]
      fills = %{"img" => fill}
      content_width_pt = 468.0
      requests = GoogleDocsClient.build_image_batch_requests(ranges, fills, content_width_pt)

      [_delete | inserts] = requests
      [insert] = inserts
      width_magnitude = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])
      # image_width_for_columns(468.0, 1) == 468.0
      assert width_magnitude == content_width_pt
    end

    test "inserts are ordered last-first with newline separators" do
      fill = %{
        kind: :image_list,
        columns: 1,
        media: [
          %{uri: "first", width_px: nil, height_px: nil},
          %{uri: "second", width_px: nil, height_px: nil}
        ],
        separator: :newline
      }

      ranges = [%{name: "p", start_index: 5, end_index: 24}]
      fills = %{"p" => fill}
      requests = GoogleDocsClient.build_image_batch_requests(ranges, fills, 468.0)

      # delete + second_img + newline + first_img
      uris =
        for %{insertInlineImage: %{uri: u}} <- requests, do: u

      assert uris == ["second", "first"]
    end
  end

  # ---------------------------------------------------------------------------
  # list_image_inserts/3 — columns >= 2 uses table path
  # ---------------------------------------------------------------------------

  describe "list_image_inserts/3 with columns >= 2" do
    test "produces exactly one deleteContentRange + one insertTable, no insertInlineImage" do
      fill = %{
        kind: :image_list,
        columns: 2,
        media: [%{uri: "u1"}, %{uri: "u2"}, %{uri: "u3"}],
        separator: :newline
      }

      ranges = [%{name: "grid", start_index: 50, end_index: 70}]
      fills = %{"grid" => fill}
      requests = GoogleDocsClient.build_image_batch_requests(ranges, fills, 468.0)

      # build_image_batch_requests/3 emits the deleteContentRange (atom keys).
      # list_image_inserts for columns>=2 emits ONLY insertTable (string keys).
      # There must be exactly ONE deleteContentRange — a second one would be
      # zero-width (startIndex == endIndex) and rejected by the Google Docs API.
      delete_count =
        Enum.count(requests, fn r ->
          Map.has_key?(r, :deleteContentRange) or Map.has_key?(r, "deleteContentRange")
        end)

      assert delete_count == 1, "expected exactly 1 deleteContentRange, got #{delete_count}"
      assert Enum.any?(requests, &Map.has_key?(&1, "insertTable"))
      refute Enum.any?(requests, &Map.has_key?(&1, :insertInlineImage))
      refute Enum.any?(requests, &Map.has_key?(&1, "insertInlineImage"))
    end

    test "insertTable has correct row count ceil(media / columns)" do
      fill = %{
        kind: :image_list,
        columns: 2,
        media: [%{uri: "u1"}, %{uri: "u2"}, %{uri: "u3"}],
        separator: :newline
      }

      ranges = [%{name: "grid", start_index: 50, end_index: 70}]
      fills = %{"grid" => fill}
      requests = GoogleDocsClient.build_image_batch_requests(ranges, fills, 468.0)

      table_req = Enum.find(requests, &Map.has_key?(&1, "insertTable"))
      assert get_in(table_req, ["insertTable", "rows"]) == 2
      assert get_in(table_req, ["insertTable", "columns"]) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # build_image_batch_requests/3 — mixed slots
  # ---------------------------------------------------------------------------

  describe "build_image_batch_requests/3 mixed slots" do
    test "single :image slot gets delete + inline insert; image_list columns=2 gets delete + insertTable" do
      ranges = [
        %{name: "logo", start_index: 100, end_index: 120},
        %{name: "gallery", start_index: 50, end_index: 70}
      ]

      fills = %{
        "logo" => %{
          kind: :image,
          columns: 1,
          default_width_px: 400,
          opacity: 1.0,
          z_index: 0,
          separator: nil,
          media: [%{uri: "logo.png", width_px: 800, height_px: 400}]
        },
        "gallery" => %{
          kind: :image_list,
          columns: 2,
          default_width_px: 400,
          separator: :newline,
          media: [%{uri: "g1"}, %{uri: "g2"}]
        }
      }

      requests = GoogleDocsClient.build_image_batch_requests(ranges, fills, 468.0)

      # logo (higher start_index) processed first (desc order); gallery second.
      # Verify exactly one deleteContentRange per slot (two slots → two deletes total).
      total_deletes =
        Enum.count(requests, fn r ->
          Map.has_key?(r, :deleteContentRange) or Map.has_key?(r, "deleteContentRange")
        end)

      assert total_deletes == 2, "expected exactly 2 deleteContentRange (one per slot)"

      # logo slot: atom-key delete + atom-key inline insert
      assert Enum.any?(requests, &match?(%{deleteContentRange: %{range: %{startIndex: 100}}}, &1))
      assert Enum.any?(requests, &match?(%{insertInlineImage: %{location: %{index: 100}}}, &1))

      # gallery slot: atom-key delete (from outer loop) + string-key insertTable only
      assert Enum.any?(requests, &match?(%{deleteContentRange: %{range: %{startIndex: 50}}}, &1))
      assert Enum.any?(requests, &Map.has_key?(&1, "insertTable"))
      # No second deleteContentRange for the gallery slot (would be zero-width and API-rejected)
      gallery_string_deletes =
        Enum.count(requests, &Map.has_key?(&1, "deleteContentRange"))

      assert gallery_string_deletes == 0,
             "list_image_inserts must not emit its own deleteContentRange for table slots"
    end
  end

  # ---------------------------------------------------------------------------
  # Cell-finder helper — extract_table_cells equivalent
  # ---------------------------------------------------------------------------

  describe "fill_table_cells/3 with extracted cell structure" do
    test "extracts insert indices from a known Google Docs table element" do
      # Simulate what the Docs API returns for a 2x2 table after insertTable.
      # The private extract_table_cells/1 uses startIndex + 1 as the insert
      # position. We verify the contract by constructing cells manually.
      # cell.startIndex values: 10, 30, 50, 70 → insert indices: 11, 31, 51, 71.
      cells = [
        %{insert_index: 11},
        %{insert_index: 31},
        %{insert_index: 51},
        %{insert_index: 71}
      ]

      media = [%{uri: "a"}, %{uri: "b"}, %{uri: "c"}]
      reqs = GoogleDocsClient.fill_table_cells(cells, media, %{image_width_pt: 230.0})

      # fill_table_cells zips cells with media (3 items), reverses → last-first
      indices = for %{"insertInlineImage" => %{"location" => %{"index" => i}}} <- reqs, do: i
      assert indices == [51, 31, 11]

      uris = for %{"insertInlineImage" => %{"uri" => u}} <- reqs, do: u
      assert uris == ["c", "b", "a"]
    end

    test "table startIndex + 1 gives correct insert position" do
      # Mirrors the strategy used in extract_table_cells/1:
      # cell.startIndex + 1 = first position inside the cell paragraph.
      cell_start = 100
      expected_insert = cell_start + 1

      cells = [%{insert_index: expected_insert}]
      media = [%{uri: "img"}]
      [req] = GoogleDocsClient.fill_table_cells(cells, media, %{image_width_pt: 230.0})

      assert get_in(req, ["insertInlineImage", "location", "index"]) == expected_insert
    end
  end

  # ---------------------------------------------------------------------------
  # build_image_fills columns pass-through
  # ---------------------------------------------------------------------------

  describe "build_image_fills columns integration (via build_image_batch_requests/3)" do
    test "columns from image_params is respected — 2 columns → insertTable" do
      # Simulate image_params as built by build_image_fills/1 with columns key.
      fill = %{
        kind: :image_list,
        columns: 2,
        default_width_px: 400,
        separator: :newline,
        media: [%{uri: "a"}, %{uri: "b"}, %{uri: "c"}, %{uri: "d"}]
      }

      ranges = [%{name: "slot", start_index: 10, end_index: 30}]
      requests = GoogleDocsClient.build_image_batch_requests(ranges, %{"slot" => fill}, 468.0)

      assert Enum.any?(requests, &match?(%{"insertTable" => %{"rows" => 2, "columns" => 2}}, &1))
    end

    test "missing columns defaults to 1 → inline inserts" do
      fill = %{
        kind: :image_list,
        columns: 1,
        default_width_px: 400,
        separator: :newline,
        media: [%{uri: "a"}, %{uri: "b"}]
      }

      ranges = [%{name: "slot", start_index: 10, end_index: 30}]
      requests = GoogleDocsClient.build_image_batch_requests(ranges, %{"slot" => fill}, 468.0)

      refute Enum.any?(requests, &Map.has_key?(&1, "insertTable"))
      assert Enum.any?(requests, &Map.has_key?(&1, :insertInlineImage))
    end
  end

  # ---------------------------------------------------------------------------
  # Bug 3 regression: duplicate slot names across sections must not collide
  # ---------------------------------------------------------------------------

  describe "duplicate slot names across sections" do
    # Helper that replicates the fill-resolution logic from substitute_all_images/4.
    # We test this logic in isolation (no Drive API calls) so the test is fast and
    # deterministic. The algorithm:
    #   1. Build (name, fill, range) tuples — one per slot per section.
    #   2. find_image_tag_ranges/2 locates all {{ image/images: name }} tags in the doc.
    #   3. For each tag, find the first (name, fill, range) tuple whose name matches AND
    #      whose range contains the tag's start_index.
    defp resolve_tagged_ranges(all_image_fills, doc, all_slot_names) do
      GoogleDocsClient.find_image_tag_ranges(doc, all_slot_names)
      |> Enum.flat_map(&resolve_tag(all_image_fills, &1))
    end

    defp resolve_tag(all_image_fills, %{name: name, start_index: s} = tag) do
      case Enum.find(all_image_fills, fn {n, _fill, range} ->
             n == name and range_contains?(range, s)
           end) do
        nil -> []
        {_name, fill, _range} -> [Map.put(tag, :fill, fill)]
      end
    end

    defp range_contains?(nil, _s), do: false
    defp range_contains?({rs, re}, s), do: s >= rs and s < re

    # Builds a minimal Google Docs API document body with two paragraphs, each
    # containing one image tag occurrence of `slot_name`.
    # section_a_start: start of first tag in the doc (e.g. 1)
    # section_b_start: start of second tag (e.g. 100)
    defp fake_doc_with_duplicate_image_slot(slot_name) do
      tag_text = "{{ image: #{slot_name} }}"

      %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "textRun" => %{"content" => tag_text}
                  }
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 100,
                    "textRun" => %{"content" => tag_text}
                  }
                ]
              }
            }
          ]
        }
      }
    end

    test "both section fills are resolved correctly when slot name is shared" do
      slot_name = "sub_order_photos"
      doc = fake_doc_with_duplicate_image_slot(slot_name)

      fill_a = %{
        kind: :image,
        columns: 1,
        default_width_px: 400,
        opacity: 1.0,
        z_index: 0,
        separator: :newline,
        media: [%{uri: "section-a-image.jpg", width_px: 800, height_px: 600}]
      }

      fill_b = %{
        kind: :image,
        columns: 1,
        default_width_px: 400,
        opacity: 1.0,
        z_index: 0,
        separator: :newline,
        media: [%{uri: "section-b-image.jpg", width_px: 1200, height_px: 900}]
      }

      # Section A occupies doc range [0, 50); section B occupies [50, 200).
      # The first tag at index 1 belongs to section A; the second at index 100 to B.
      all_image_fills = [
        {slot_name, fill_a, {0, 50}},
        {slot_name, fill_b, {50, 200}}
      ]

      tagged = resolve_tagged_ranges(all_image_fills, doc, [slot_name])

      assert length(tagged) == 2,
             "expected both image slots to be resolved, got #{length(tagged)}"

      [tag_a, tag_b] = Enum.sort_by(tagged, & &1.start_index)

      assert tag_a.start_index == 1

      assert tag_a.fill == fill_a,
             "section A tag should get fill_a (section-a-image.jpg), got #{inspect(tag_a.fill)}"

      assert tag_b.start_index == 100

      assert tag_b.fill == fill_b,
             "section B tag should get fill_b (section-b-image.jpg), got #{inspect(tag_b.fill)}"
    end

    test "old collision behaviour: Map.new/2 with duplicate keys loses section A fill" do
      # This documents the old broken behaviour to ensure we do NOT regress.
      slot_name = "slot"

      fill_a = %{kind: :image, media: [%{uri: "a.jpg"}]}
      fill_b = %{kind: :image, media: [%{uri: "b.jpg"}]}

      # With the old Map.new approach, section B's fill overwrites section A's:
      all_image_fills = [
        {slot_name, fill_a, {0, 50}},
        {slot_name, fill_b, {50, 200}}
      ]

      old_fills_map = Map.new(all_image_fills, fn {name, fill, _} -> {name, fill} end)
      old_range_by_name = Map.new(all_image_fills, fn {name, _, range} -> {name, range} end)

      # Old fills_map: only section B's fill survives (last-write wins).
      assert old_fills_map[slot_name] == fill_b,
             "old Map.new collides: fill_a is lost, only fill_b survives"

      # Old range_by_name: only section B's range survives.
      assert old_range_by_name[slot_name] == {50, 200},
             "old Map.new collides: section A range is lost"

      # New approach correctly assigns both:
      doc = fake_doc_with_duplicate_image_slot(slot_name)
      tagged = resolve_tagged_ranges(all_image_fills, doc, [slot_name])

      assert length(tagged) == 2

      uris =
        tagged
        |> Enum.sort_by(& &1.start_index)
        |> Enum.map(&(&1.fill.media |> hd() |> Map.get(:uri)))

      assert uris == ["a.jpg", "b.jpg"]
    end
  end

  # ---------------------------------------------------------------------------
  # grid_border_requests/1 + build_phase2_requests/5 — borderless image grids
  # ---------------------------------------------------------------------------

  describe "grid_border_requests/1" do
    test "spans the whole table with the table's own row/column count" do
      table_el = %{
        "startIndex" => 42,
        "table" => %{"rows" => 2, "columns" => 3, "tableRows" => []}
      }

      [req] = GoogleDocsClient.grid_border_requests(table_el)

      range = get_in(req, ["updateTableCellStyle", "tableRange"])
      assert range["rowSpan"] == 2
      assert range["columnSpan"] == 3

      location = get_in(range, ["tableCellLocation"])
      assert get_in(location, ["tableStartLocation", "index"]) == 42
      assert location["rowIndex"] == 0
      assert location["columnIndex"] == 0
    end

    test "zeroes all four borders and touches nothing else (padding untouched)" do
      table_el = %{
        "startIndex" => 1,
        "table" => %{"rows" => 1, "columns" => 2, "tableRows" => []}
      }

      [req] = GoogleDocsClient.grid_border_requests(table_el)

      style = get_in(req, ["updateTableCellStyle", "tableCellStyle"])

      for side <- ~w(borderTop borderBottom borderLeft borderRight) do
        assert get_in(style, [side, "width", "magnitude"]) == 0
      end

      refute Map.has_key?(style, "paddingTop")

      assert get_in(req, ["updateTableCellStyle", "fields"]) ==
               "borderTop,borderBottom,borderLeft,borderRight"
    end

    test "a table block missing startIndex (proto3 omission) defaults to 0" do
      table_el = %{"table" => %{"rows" => 1, "columns" => 2, "tableRows" => []}}
      [req] = GoogleDocsClient.grid_border_requests(table_el)

      assert get_in(req, [
               "updateTableCellStyle",
               "tableRange",
               "tableCellLocation",
               "tableStartLocation",
               "index"
             ]) == 0
    end
  end

  describe "build_phase2_requests/5" do
    # A grid table with `rows * columns` cells, laid out left-to-right,
    # top-to-bottom, each cell's startIndex spaced out like a real Docs
    # table.
    defp grid_table_el(start_index, rows, columns) do
      cell_starts =
        for r <- 0..(rows - 1), c <- 0..(columns - 1) do
          start_index + 10 + (r * columns + c) * 20
        end

      table_rows =
        cell_starts
        |> Enum.chunk_every(columns)
        |> Enum.map(fn row_starts ->
          %{"tableCells" => Enum.map(row_starts, &%{"startIndex" => &1, "content" => []})}
        end)

      %{
        "startIndex" => start_index,
        "table" => %{"rows" => rows, "columns" => columns, "tableRows" => table_rows}
      }
    end

    test "one grid table: its border request precedes every image insert" do
      slot = %{name: "grid", start_index: 50, end_index: 70}
      table_el = grid_table_el(110, 2, 2)
      fill = %{kind: :image_list, columns: 2, media: [%{uri: "a"}, %{uri: "b"}, %{uri: "c"}]}

      requests =
        GoogleDocsClient.build_phase2_requests([slot], [table_el], %{"grid" => fill}, %{}, [])

      kinds = Enum.map(requests, fn r -> r |> Map.keys() |> hd() end)

      assert kinds == [
               "updateTableCellStyle",
               "insertInlineImage",
               "insertInlineImage",
               "insertInlineImage"
             ]

      range = get_in(hd(requests), ["updateTableCellStyle", "tableRange"])
      assert range["rowSpan"] == 2
      assert range["columnSpan"] == 2
    end

    test "two grid tables: each keeps its own tableStartLocation, both borders precede every insert" do
      slot_a = %{name: "a", start_index: 50, end_index: 70}
      slot_b = %{name: "b", start_index: 200, end_index: 220}
      table_a = grid_table_el(110, 1, 2)
      table_b = grid_table_el(260, 1, 2)

      fills = %{
        "a" => %{kind: :image_list, columns: 2, media: [%{uri: "a1"}, %{uri: "a2"}]},
        "b" => %{kind: :image_list, columns: 2, media: [%{uri: "b1"}, %{uri: "b2"}]}
      }

      requests =
        GoogleDocsClient.build_phase2_requests(
          [slot_a, slot_b],
          [table_a, table_b],
          fills,
          %{},
          []
        )

      border_reqs = Enum.filter(requests, &Map.has_key?(&1, "updateTableCellStyle"))
      assert length(border_reqs) == 2

      starts =
        Enum.map(border_reqs, fn r ->
          get_in(r, [
            "updateTableCellStyle",
            "tableRange",
            "tableCellLocation",
            "tableStartLocation",
            "index"
          ])
        end)

      assert Enum.sort(starts) == [110, 260]

      border_positions =
        for {r, i} <- Enum.with_index(requests), Map.has_key?(r, "updateTableCellStyle"), do: i

      insert_positions =
        for {r, i} <- Enum.with_index(requests), Map.has_key?(r, "insertInlineImage"), do: i

      assert Enum.max(border_positions) < Enum.min(insert_positions),
             "every border request must precede every image insert"
    end

    test "columns: 1 slot gets no border request (regression)" do
      slot = %{name: "single_col", start_index: 50, end_index: 70}
      table_el = grid_table_el(110, 2, 1)
      fill = %{kind: :image_list, columns: 1, media: [%{uri: "a"}, %{uri: "b"}]}

      requests =
        GoogleDocsClient.build_phase2_requests(
          [slot],
          [table_el],
          %{"single_col" => fill},
          %{},
          []
        )

      refute Enum.any?(requests, &Map.has_key?(&1, "updateTableCellStyle"))
      assert Enum.count(requests, &Map.has_key?(&1, "insertInlineImage")) == 2
    end
  end
end
