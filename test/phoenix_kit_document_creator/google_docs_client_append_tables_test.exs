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

  # Builds a table StructuralElement matching the REAL Docs API response
  # shape, for simulating an already-inserted table in a target document
  # (as opposed to `table_block/1`, which builds a *template's* table for
  # `flatten_template_with_table_markers/1` and doesn't need a position).
  # `startIndex`/`endIndex` are fields of the block itself — siblings of
  # "table" — never nested inside it; see `collect_tables/1`'s comment in
  # the implementation. A single-row table with one bare (empty) cell per
  # entry in `cell_starts`.
  defp skeleton_table_block(start_index, end_index, cell_starts) do
    %{
      "startIndex" => start_index,
      "endIndex" => end_index,
      "table" => %{
        "tableRows" => [
          %{"tableCells" => Enum.map(cell_starts, &%{"startIndex" => &1, "content" => []})}
        ]
      }
    }
  end

  # Same shape as `skeleton_table_block/3`, but cells carry real text —
  # simulating a table from an earlier section that has already been
  # through Phase 2 (fill_table_cells_text/2).
  defp filled_table_block(start_index, end_index, cell_start_texts) do
    %{
      "startIndex" => start_index,
      "endIndex" => end_index,
      "table" => %{
        "tableRows" => [
          %{
            "tableCells" =>
              Enum.map(cell_start_texts, fn {cell_start, text} ->
                %{
                  "startIndex" => cell_start,
                  "content" => [
                    %{
                      "paragraph" => %{
                        "elements" => [%{"textRun" => %{"content" => text <> "\n"}}]
                      }
                    }
                  ]
                }
              end)
          }
        ]
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
      # last-first fill ordering is observable. `startIndex`/`endIndex` are
      # fields of the block itself (sibling of "table"), matching the real
      # Docs API shape — the "table" object itself has no startIndex of its
      # own (see collect_tables/1's comment).
      doc2 = %{
        "body" => %{
          "content" => [
            %{
              "startIndex" => marker_start,
              "table" => %{
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

  describe "append_template/3 — regression: pre-existing table position must come from the block, not nested under \"table\"" do
    # Root cause this suite guards against: `finish_append_template/6` used
    # to read a pre-existing table's document position as
    # `el["table"]["startIndex"]`. The real Docs API has no such nested
    # field (see `collect_tables/1`'s comment) — that lookup always
    # returned `nil`. `match_new_tables/3` sorts `{start_index, tag}` pairs
    # to reconstruct document order; mixing real integers (this section's
    # new markers) with `nil` (every pre-existing table) doesn't sort by
    # position at all — Erlang term ordering puts every number before every
    # atom, so *every* pre-existing table sorted after *every* new one,
    # regardless of where either actually sat in the document. A second
    # table-bearing section would then have its cell text written into the
    # first section's already-filled tables instead of its own, exactly the
    # "content from many different tables mashed into one" corruption seen
    # in production composed documents.
    #
    # These mocks intentionally use the correct (real) shape everywhere —
    # that's what makes them exercise the bug: fixtures that mirrored the
    # bug (startIndex nested under "table", as the pre-fix version of the
    # happy-path test above did) can't fail on pre-fix code.
    test "a second table-bearing section fills its own new tables, not the first section's already-filled ones" do
      # --- Section 1: template A, two tables, appended into a near-empty doc ---
      template_a = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Head\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["A1a\n", "A1b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Mid\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["A2a\n", "A2b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Tail\n"}}]}}
          ]
        }
      }

      {text_a, [_ta1, _ta2]} = GoogleDocsClient.flatten_template_with_table_markers(template_a)

      target_doc_0 = %{
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

      doc1_1 = %{
        "body" => %{
          "content" =>
            target_doc_0["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [%{"startIndex" => 10, "textRun" => %{"content" => text_a}}]
                  }
                }
              ]
        }
      }

      [%{marker_index: 1, start_index: ma1}, %{marker_index: 2, start_index: ma2}] =
        GoogleDocsClient.find_table_marker_ranges(doc1_1)

      doc2_1 = %{
        "body" => %{
          "content" => [
            hd(target_doc_0["body"]["content"]),
            skeleton_table_block(ma1, ma1 + 30, [ma1 + 10, ma1 + 13]),
            skeleton_table_block(ma2, ma2 + 30, [ma2 + 10, ma2 + 13])
          ]
        }
      }

      final_doc_1 = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 500}]}}
          ]
        }
      }

      calls_1 = :counters.new(1, [])

      get_fn_1 = fn
        "template-a" ->
          {:ok, %{body: template_a}}

        "target-id" ->
          call = :counters.get(calls_1, 1)
          :counters.add(calls_1, 1, 1)

          case call do
            0 -> {:ok, %{body: target_doc_0}}
            1 -> {:ok, %{body: doc1_1}}
            2 -> {:ok, %{body: doc2_1}}
            3 -> {:ok, %{body: final_doc_1}}
          end
      end

      batch_fn_1 = fn "target-id", requests ->
        send(self(), {:call1_batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {10, 499}} =
               GoogleDocsClient.append_template("target-id", "template-a",
                 get_fn: get_fn_1,
                 batch_fn: batch_fn_1
               )

      # Drain section 1's three batches (page-break+text, skeleton, fill) —
      # section 2 is what's under test.
      assert_receive {:call1_batch, _}
      assert_receive {:call1_batch, _}
      assert_receive {:call1_batch, _}
      refute_receive {:call1_batch, _}

      # --- Section 2: template B, two tables, appended into a doc that
      # already has section 1's two REAL, filled tables at ma1/ma2. ---
      template_b = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Head\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["B1a\n", "B1b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Mid\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["B2a\n", "B2b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Tail\n"}}]}}
          ]
        }
      }

      {text_b, [_tb1, _tb2]} = GoogleDocsClient.flatten_template_with_table_markers(template_b)

      current_doc_2 = %{
        "body" => %{
          "content" => [
            hd(target_doc_0["body"]["content"]),
            filled_table_block(ma1, ma1 + 30, [{ma1 + 10, "A1a"}, {ma1 + 13, "A1b"}]),
            filled_table_block(ma2, ma2 + 30, [{ma2 + 10, "A2a"}, {ma2 + 13, "A2b"}]),
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => ma2 + 30,
                    "endIndex" => ma2 + 31,
                    "textRun" => %{"content" => "\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      content_start_2 = ma2 + 31

      doc1_2 = %{
        "body" => %{
          "content" =>
            current_doc_2["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [
                      %{"startIndex" => content_start_2, "textRun" => %{"content" => text_b}}
                    ]
                  }
                }
              ]
        }
      }

      marker_ranges_2 = GoogleDocsClient.find_table_marker_ranges(doc1_2)

      # Section 2's own markers are found — and ONLY section 2's markers.
      # Section 1's tables are already real content by this point (no
      # marker tokens left behind), so there is no cross-section marker
      # collision even though both templates' markers start numbering at 1.
      assert [%{marker_index: 1, start_index: mb1}, %{marker_index: 2, start_index: mb2}] =
               marker_ranges_2

      doc2_2 = %{
        "body" => %{
          "content" => [
            hd(current_doc_2["body"]["content"]),
            filled_table_block(ma1, ma1 + 30, [{ma1 + 10, "A1a"}, {ma1 + 13, "A1b"}]),
            filled_table_block(ma2, ma2 + 30, [{ma2 + 10, "A2a"}, {ma2 + 13, "A2b"}]),
            skeleton_table_block(mb1, mb1 + 30, [mb1 + 10, mb1 + 13]),
            skeleton_table_block(mb2, mb2 + 30, [mb2 + 10, mb2 + 13])
          ]
        }
      }

      final_doc_2 = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 800}]}}
          ]
        }
      }

      calls_2 = :counters.new(1, [])

      get_fn_2 = fn
        "template-b" ->
          {:ok, %{body: template_b}}

        "target-id" ->
          call = :counters.get(calls_2, 1)
          :counters.add(calls_2, 1, 1)

          case call do
            0 -> {:ok, %{body: current_doc_2}}
            1 -> {:ok, %{body: doc1_2}}
            2 -> {:ok, %{body: doc2_2}}
            3 -> {:ok, %{body: final_doc_2}}
          end
      end

      batch_fn_2 = fn "target-id", requests ->
        send(self(), {:call2_batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {^content_start_2, 799}} =
               GoogleDocsClient.append_template("target-id", "template-b",
                 get_fn: get_fn_2,
                 batch_fn: batch_fn_2
               )

      # Phase 0 (page break + marker text) and Phase 1 (skeleton) batches —
      # not under test here.
      assert_receive {:call2_batch, _}
      assert_receive {:call2_batch, _}

      # Phase 2: the regression itself. Section 2's cell text must land in
      # section 2's own (newly-created) tables — mb1/mb2 — never in section
      # 1's already-filled tables at ma1/ma2.
      assert_receive {:call2_batch, fill_requests}
      refute_receive {:call2_batch, _}

      fill_targets =
        Enum.map(fill_requests, fn %{
                                     "insertText" => %{
                                       "location" => %{"index" => idx},
                                       "text" => text
                                     }
                                   } ->
          {idx, text}
        end)

      assert Enum.sort(fill_targets) ==
               Enum.sort([
                 {mb1 + 11, "B1a"},
                 {mb1 + 14, "B1b"},
                 {mb2 + 11, "B2a"},
                 {mb2 + 14, "B2b"}
               ])

      refute Enum.any?(fill_targets, fn {idx, _} ->
               idx in [ma1 + 11, ma1 + 14, ma2 + 11, ma2 + 14]
             end)
    end

    test "an interleaved zero-table (image-only) section doesn't perturb a later section's pre-existing-table bookkeeping" do
      # Section 1: one table.
      template_a = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Head\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["A1a\n", "A1b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Tail\n"}}]}}
          ]
        }
      }

      {text_a, [_ta]} = GoogleDocsClient.flatten_template_with_table_markers(template_a)

      target_doc_0 = %{
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

      doc1_1 = %{
        "body" => %{
          "content" =>
            target_doc_0["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [%{"startIndex" => 10, "textRun" => %{"content" => text_a}}]
                  }
                }
              ]
        }
      }

      [%{marker_index: 1, start_index: ma}] = GoogleDocsClient.find_table_marker_ranges(doc1_1)

      doc2_1 = %{
        "body" => %{
          "content" => [
            hd(target_doc_0["body"]["content"]),
            skeleton_table_block(ma, ma + 30, [ma + 10, ma + 13])
          ]
        }
      }

      final_doc_1 = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 300}]}}
          ]
        }
      }

      calls_1 = :counters.new(1, [])

      get_fn_1 = fn
        "template-a" ->
          {:ok, %{body: template_a}}

        "target-id" ->
          call = :counters.get(calls_1, 1)
          :counters.add(calls_1, 1, 1)

          case call do
            0 -> {:ok, %{body: target_doc_0}}
            1 -> {:ok, %{body: doc1_1}}
            2 -> {:ok, %{body: doc2_1}}
            3 -> {:ok, %{body: final_doc_1}}
          end
      end

      batch_fn_1 = fn "target-id", requests ->
        send(self(), {:batch1, requests})
        {:ok, %{}}
      end

      assert {:ok, {10, 299}} =
               GoogleDocsClient.append_template("target-id", "template-a",
                 get_fn: get_fn_1,
                 batch_fn: batch_fn_1
               )

      assert_receive {:batch1, _}
      assert_receive {:batch1, _}
      assert_receive {:batch1, _}
      refute_receive {:batch1, _}

      # Section 2: image-only, zero tables — mirrors a real template whose
      # body is only inline images with no real text (e.g. an inline image
      # element followed by the paragraph's own trailing newline), which
      # flattens to a near-empty "\n". Exercises the no-tables fast path:
      # single insertText, no extra Docs API calls (see the "no tables"
      # regression test above).
      template_c = %{
        "body" => %{
          "content" => [%{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "\n"}}]}}]
        }
      }

      current_doc_2 = %{
        "body" => %{
          "content" => [
            hd(target_doc_0["body"]["content"]),
            filled_table_block(ma, ma + 30, [{ma + 10, "A1a"}, {ma + 13, "A1b"}]),
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => ma + 30,
                    "endIndex" => ma + 31,
                    "textRun" => %{"content" => "\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_fn_2 = fn
        "template-c" -> {:ok, %{body: template_c}}
        "target-id" -> {:ok, %{body: current_doc_2}}
      end

      batch_fn_2 = fn "target-id", requests ->
        send(self(), {:batch2, requests})
        {:ok, %{}}
      end

      section2_content_start = ma + 31

      assert {:ok, {^section2_content_start, section2_content_end}} =
               GoogleDocsClient.append_template("target-id", "template-c",
                 get_fn: get_fn_2,
                 batch_fn: batch_fn_2
               )

      assert_receive {:batch2, _}
      refute_receive {:batch2, _}

      # Section 3: another table, appended after the image-only section.
      # Its own new table must be matched correctly — section 1's table (at
      # `ma`) must still be recognized as pre-existing despite the
      # zero-table section 2 sitting between them.
      template_b = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Head\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["B1a\n", "B1b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Tail\n"}}]}}
          ]
        }
      }

      {text_b, [_tb]} = GoogleDocsClient.flatten_template_with_table_markers(template_b)

      current_doc_3 = %{
        "body" => %{
          "content" =>
            current_doc_2["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [
                      %{
                        "startIndex" => section2_content_start,
                        "endIndex" => section2_content_end,
                        "textRun" => %{"content" => "\n"}
                      }
                    ]
                  }
                }
              ]
        }
      }

      doc1_3 = %{
        "body" => %{
          "content" =>
            current_doc_3["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [
                      %{"startIndex" => section2_content_end, "textRun" => %{"content" => text_b}}
                    ]
                  }
                }
              ]
        }
      }

      [%{marker_index: 1, start_index: mb}] = GoogleDocsClient.find_table_marker_ranges(doc1_3)

      doc2_3 = %{
        "body" => %{
          "content" => [
            hd(current_doc_3["body"]["content"]),
            filled_table_block(ma, ma + 30, [{ma + 10, "A1a"}, {ma + 13, "A1b"}]),
            skeleton_table_block(mb, mb + 30, [mb + 10, mb + 13])
          ]
        }
      }

      final_doc_3 = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 900}]}}
          ]
        }
      }

      calls_3 = :counters.new(1, [])

      get_fn_3 = fn
        "template-b" ->
          {:ok, %{body: template_b}}

        "target-id" ->
          call = :counters.get(calls_3, 1)
          :counters.add(calls_3, 1, 1)

          case call do
            0 -> {:ok, %{body: current_doc_3}}
            1 -> {:ok, %{body: doc1_3}}
            2 -> {:ok, %{body: doc2_3}}
            3 -> {:ok, %{body: final_doc_3}}
          end
      end

      batch_fn_3 = fn "target-id", requests ->
        send(self(), {:batch3, requests})
        {:ok, %{}}
      end

      assert {:ok, {_start3, 899}} =
               GoogleDocsClient.append_template("target-id", "template-b",
                 get_fn: get_fn_3,
                 batch_fn: batch_fn_3
               )

      assert_receive {:batch3, _}
      assert_receive {:batch3, _}
      assert_receive {:batch3, fill_requests_3}
      refute_receive {:batch3, _}

      fill_targets_3 =
        Enum.map(fill_requests_3, fn %{
                                       "insertText" => %{
                                         "location" => %{"index" => idx},
                                         "text" => text
                                       }
                                     } ->
          {idx, text}
        end)

      assert Enum.sort(fill_targets_3) == Enum.sort([{mb + 11, "B1a"}, {mb + 14, "B1b"}])
      refute Enum.any?(fill_targets_3, fn {idx, _} -> idx in [ma + 11, ma + 14] end)
    end
  end
end
