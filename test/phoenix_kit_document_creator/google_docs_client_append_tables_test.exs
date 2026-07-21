defmodule PhoenixKitDocumentCreator.GoogleDocsClientAppendTablesTest do
  @moduledoc """
  Coverage for the append-with-tables pipeline described in
  `GoogleDocsClient.append_template/3`'s doc: `append_template/2` used to
  flatten a template via `get_document_text/1`, which silently dropped every
  table (and any `{{var}}` placeholder that lived only inside one). These
  tests cover the fix: `flatten_template_with_table_markers/1` (Phase 0),
  `find_table_marker_ranges/1` + `table_skeleton_requests/2` (Phase 1),
  `fill_table_cells_text/2` (Phase 2), and the full `append_template/3`
  orchestration via injected `:get_fn`/`:batch_fn`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # Minimal single-paragraph document, mirrors the helper used throughout the
  # sibling GoogleDocsClient test files.
  defp doc_with_text(text, start_index) do
    %{
      "body" => %{
        "content" => [
          %{
            "paragraph" => %{
              "elements" => [
                %{"startIndex" => start_index, "textRun" => %{"content" => text}}
              ]
            }
          }
        ]
      }
    }
  end

  defp table_block(opts) do
    rows = Keyword.fetch!(opts, :rows)
    row_texts = Keyword.fetch!(opts, :row_texts)

    table_rows =
      Enum.map(row_texts, fn cell_texts ->
        %{
          "tableCells" =>
            Enum.map(cell_texts, fn
              nil ->
                %{"content" => []}

              text ->
                %{
                  "content" => [
                    %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => text}}]}}
                  ]
                }
            end)
        }
      end)

    %{
      "table" => %{
        "rows" => rows,
        "columns" => Keyword.fetch!(opts, :columns),
        "tableRows" => table_rows
      }
    }
  end

  describe "flatten_template_with_table_markers/1" do
    test "paragraph-only document is unaffected: same join get_document_text/1 does, no markers" do
      doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Hello "}}]}},
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "World\n"}}]}}
          ]
        }
      }

      assert {"Hello World\n", []} = GoogleDocsClient.flatten_template_with_table_markers(doc)
    end

    test "a table is replaced by a unique marker and its structure captured" do
      doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Header\n"}}]}},
            table_block(rows: 2, columns: 2, row_texts: [["A1\n", "B1\n"], ["A2\n", "B2\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Footer\n"}}]}}
          ]
        }
      }

      assert {text, [table]} = GoogleDocsClient.flatten_template_with_table_markers(doc)

      # Paragraph text before/after the table is untouched and in order.
      assert String.starts_with?(text, "Header\n")
      assert String.ends_with?(text, "Footer\n")
      # No table content leaked into the flattened text as plain text.
      refute text =~ "A1"
      refute text =~ "B1"

      assert table.marker_index == 1
      assert table.rows == 2
      assert table.columns == 2
      assert table.cell_texts == ["A1", "B1", "A2", "B2"]
    end

    test "multiple tables get distinct, ordered marker indices" do
      doc = %{
        "body" => %{
          "content" => [
            table_block(rows: 1, columns: 1, row_texts: [["First\n"]]),
            table_block(rows: 1, columns: 1, row_texts: [["Second\n"]])
          ]
        }
      }

      assert {_text, [t1, t2]} = GoogleDocsClient.flatten_template_with_table_markers(doc)
      assert t1.marker_index == 1
      assert t1.cell_texts == ["First"]
      assert t2.marker_index == 2
      assert t2.cell_texts == ["Second"]
    end

    test "a multi-paragraph cell keeps internal newlines, drops only the final one" do
      doc = %{
        "body" => %{
          "content" => [
            table_block(
              rows: 1,
              columns: 1,
              row_texts: [
                [
                  # Two paragraphs concatenated inside one cell, exactly how
                  # get_document_text/1 would join them at the top level.
                  "Nimi: {{ customer_name }}\nAadress: {{ customer_address }}\n"
                ]
              ]
            )
          ]
        }
      }

      assert {_text, [table]} = GoogleDocsClient.flatten_template_with_table_markers(doc)

      assert table.cell_texts == [
               "Nimi: {{ customer_name }}\nAadress: {{ customer_address }}"
             ]
    end

    test "an empty cell captures as an empty string" do
      doc = %{
        "body" => %{"content" => [table_block(rows: 1, columns: 2, row_texts: [["Text\n", nil]])]}
      }

      assert {_text, [table]} = GoogleDocsClient.flatten_template_with_table_markers(doc)
      assert table.cell_texts == ["Text", ""]
    end

    test "table dimensions fall back to tableRows shape when rows/columns are missing" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "tableRows" => [
                  %{"tableCells" => [%{"content" => []}, %{"content" => []}]}
                ]
              }
            }
          ]
        }
      }

      assert {_text, [table]} = GoogleDocsClient.flatten_template_with_table_markers(doc)
      assert table.rows == 1
      assert table.columns == 2
    end
  end

  describe "find_table_marker_ranges/1" do
    test "locates a single marker and reports its captured index" do
      {marker_text, [%{marker_index: 1}]} =
        GoogleDocsClient.flatten_template_with_table_markers(%{
          "body" => %{"content" => [table_block(rows: 1, columns: 1, row_texts: [["x\n"]])]}
        })

      full_text = "Before " <> marker_text <> " After"
      doc = doc_with_text(full_text, 1)

      assert [range] = GoogleDocsClient.find_table_marker_ranges(doc)
      assert range.marker_index == 1

      # Round-trip: slicing the original text at the reported range yields
      # back exactly the marker substring (proves the byte->UTF-16 index
      # arithmetic is self-consistent, ASCII-only so byte == UTF-16 unit).
      sliced =
        String.slice(full_text, range.start_index - 1, range.end_index - range.start_index)

      assert sliced == marker_text
    end

    test "locates multiple markers in document order" do
      {_t1, [%{marker_index: 1}]} =
        GoogleDocsClient.flatten_template_with_table_markers(%{
          "body" => %{"content" => [table_block(rows: 1, columns: 1, row_texts: [["a\n"]])]}
        })

      marker1 = " __PKDC_TABLE_1__ "
      marker2 = " __PKDC_TABLE_2__ "
      doc = doc_with_text("X" <> marker1 <> "Y" <> marker2 <> "Z", 1)

      ranges = GoogleDocsClient.find_table_marker_ranges(doc)
      assert Enum.map(ranges, & &1.marker_index) == [1, 2]
      assert Enum.at(ranges, 0).start_index < Enum.at(ranges, 1).start_index
    end

    test "returns [] when no markers are present" do
      doc = doc_with_text("nothing special here", 1)
      assert GoogleDocsClient.find_table_marker_ranges(doc) == []
    end
  end

  describe "table_skeleton_requests/2" do
    test "builds delete + insertTable pairs, descending by start_index" do
      marker_ranges = [
        %{marker_index: 1, start_index: 10, end_index: 28},
        %{marker_index: 2, start_index: 50, end_index: 68}
      ]

      tables_by_index = %{
        1 => %{rows: 2, columns: 2},
        2 => %{rows: 1, columns: 3}
      }

      reqs = GoogleDocsClient.table_skeleton_requests(marker_ranges, tables_by_index)

      assert [
               %{"deleteContentRange" => %{"range" => %{"startIndex" => 50, "endIndex" => 68}}},
               %{"insertTable" => %{"rows" => 1, "columns" => 3, "location" => %{"index" => 50}}},
               %{"deleteContentRange" => %{"range" => %{"startIndex" => 10, "endIndex" => 28}}},
               %{"insertTable" => %{"rows" => 2, "columns" => 2, "location" => %{"index" => 10}}}
             ] = reqs
    end
  end

  describe "fill_table_cells_text/2" do
    test "inserts each cell's text, last-first" do
      cells = [%{insert_index: 101}, %{insert_index: 104}]
      reqs = GoogleDocsClient.fill_table_cells_text(cells, ["X", "Y"])

      assert reqs == [
               %{"insertText" => %{"location" => %{"index" => 104}, "text" => "Y"}},
               %{"insertText" => %{"location" => %{"index" => 101}, "text" => "X"}}
             ]
    end

    test "skips cells whose captured text is empty" do
      cells = [%{insert_index: 1}, %{insert_index: 2}, %{insert_index: 3}]
      reqs = GoogleDocsClient.fill_table_cells_text(cells, ["", "middle", ""])

      assert reqs == [%{"insertText" => %{"location" => %{"index" => 2}, "text" => "middle"}}]
    end

    test "empty cell_texts list produces no requests" do
      assert GoogleDocsClient.fill_table_cells_text([%{insert_index: 1}], []) == []
    end
  end

  describe "append_template/3 — no tables (regression: unchanged behaviour)" do
    test "single insertText, no extra Docs API calls, same index math as before" do
      template_doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Plain body.\n"}}]}}
          ]
        }
      }

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          :counters.add(get_calls, 1, 1)
          {:ok, %{body: target_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {10, 22}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      # content_start=10, content_end = 10 + utf16_units("Plain body.\n") = 10+12=22
      assert_receive {:batch,
                      [
                        %{insertPageBreak: %{location: %{index: 9}}},
                        %{insertText: %{location: %{index: 10}, text: "Plain body.\n"}}
                      ]}

      refute_receive {:batch, _}
      # Only the one target-doc fetch used to compute insert_index — no
      # re-fetches for a template with zero tables.
      assert :counters.get(get_calls, 1) == 1
    end
  end

  describe "append_template/3 — with tables (three-phase pipeline)" do
    test "rebuilds the table, fills its cells, and computes content_end from the final doc" do
      template_doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Hi\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["X\n", "Y\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Bye\n"}}]}}
          ]
        }
      }

      {text, _tables} = GoogleDocsClient.flatten_template_with_table_markers(template_doc)

      initial_target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      # State after Phase 0's insertText: the marker text now lives at
      # content_start (10). Real Google Docs would split this across several
      # paragraph structural elements (one per embedded \n) — collapsed to a
      # single textRun here since find_table_marker_ranges/1 only cares about
      # locating the marker substring and its startIndex.
      doc1 = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [%{"startIndex" => 10, "textRun" => %{"content" => text}}]
              }
            }
          ]
        }
      }

      # Reuse the real function under test to locate the marker instead of
      # hand-deriving its index — keeps this fixture honest regardless of the
      # marker's exact literal format/length.
      [%{marker_index: 1, start_index: marker_start}] =
        GoogleDocsClient.find_table_marker_ranges(doc1)

      # State after Phase 1's skeleton batch: the marker is gone, replaced by
      # a bare 1x2 table. Cell startIndexes are arbitrary but distinct so
      # last-first fill ordering is observable.
      doc2 = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "startIndex" => marker_start,
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{"startIndex" => 100, "content" => []},
                      %{"startIndex" => 103, "content" => []}
                    ]
                  }
                ]
              }
            }
          ]
        }
      }

      # State after Phase 2's cell-fill batch: an arbitrary final document
      # length, used only to prove content_end comes from re-fetching the
      # real document rather than the marked-up text's length.
      final_doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 500}]}}
          ]
        }
      }

      target_docs = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(target_docs, 1)
          :counters.add(target_docs, 1, 1)

          case call do
            0 -> {:ok, %{body: initial_target_doc}}
            1 -> {:ok, %{body: doc1}}
            2 -> {:ok, %{body: doc2}}
            3 -> {:ok, %{body: final_doc}}
          end
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {10, 499}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      # Phase 0: page break + the marked-up text (marker included).
      assert_receive {:batch,
                      [
                        %{insertPageBreak: %{location: %{index: 9}}},
                        %{insertText: %{location: %{index: 10}, text: ^text}}
                      ]}

      # Phase 1: skeleton — delete the marker, insert a bare 1x2 table at its position.
      assert_receive {:batch,
                      [
                        %{"deleteContentRange" => %{"range" => %{"startIndex" => ^marker_start}}},
                        %{
                          "insertTable" => %{
                            "rows" => 1,
                            "columns" => 2,
                            "location" => %{"index" => ^marker_start}
                          }
                        }
                      ]}

      # Phase 2: cell fill — captured cell text ("X", "Y"), last-first.
      assert_receive {:batch,
                      [
                        %{"insertText" => %{"location" => %{"index" => 104}, "text" => "Y"}},
                        %{"insertText" => %{"location" => %{"index" => 101}, "text" => "X"}}
                      ]}

      refute_receive {:batch, _}
      assert :counters.get(target_docs, 1) == 4
    end

    test "returns {:error, :table_marker_count_mismatch} when a marker goes missing" do
      template_doc = %{
        "body" => %{
          "content" => [table_block(rows: 1, columns: 1, row_texts: [["x\n"]])]
        }
      }

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      # doc1 (post Phase-0 re-fetch) has NO marker text at all — simulates a
      # marker that failed to round-trip through the Docs API.
      doc1_without_marker = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(calls, 1)
          :counters.add(calls, 1, 1)
          if call == 0, do: {:ok, %{body: target_doc}}, else: {:ok, %{body: doc1_without_marker}}
      end

      batch_fn = fn _id, _requests -> {:ok, %{}} end

      assert {:error, :table_marker_count_mismatch} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )
    end

    test "returns {:error, :table_match_mismatch} when Phase 1's table can't be relocated" do
      template_doc = %{
        "body" => %{
          "content" => [table_block(rows: 1, columns: 1, row_texts: [["x\n"]])]
        }
      }

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      {text, _tables} = GoogleDocsClient.flatten_template_with_table_markers(template_doc)

      doc1 = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [%{"startIndex" => 10, "textRun" => %{"content" => text}}]
              }
            }
          ]
        }
      }

      # doc2 (post Phase-1 re-fetch) has NO tables at all — simulates the
      # skeleton insertTable silently failing to materialize.
      doc2_without_table = %{"body" => %{"content" => []}}

      calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(calls, 1)
          :counters.add(calls, 1, 1)

          case call do
            0 -> {:ok, %{body: target_doc}}
            1 -> {:ok, %{body: doc1}}
            _ -> {:ok, %{body: doc2_without_table}}
          end
      end

      batch_fn = fn _id, _requests -> {:ok, %{}} end

      assert {:error, :table_match_mismatch} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )
    end
  end
end
