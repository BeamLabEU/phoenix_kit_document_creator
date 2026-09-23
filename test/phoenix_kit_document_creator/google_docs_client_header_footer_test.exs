defmodule PhoenixKitDocumentCreator.GoogleDocsClientHeaderFooterTest do
  @moduledoc """
  Coverage for Block C: an appended section gets its OWN header/footer
  (`GoogleDocsClient.append_template/3`'s header/footer step, built on
  `SegmentReplay` — see its own test file for the fingerprint/request-shape
  unit coverage). Mock style matches
  `google_docs_client_append_tables_test.exs` (`:get_fn`/`:batch_fn`
  injection, `:counters` for a stateful re-fetch sequence).

  Also covers `header_footer_owners/3` — which section's `variable_values`
  a header/footer `{{key}}` placeholder resolves against once a document
  can hold more than one header/footer segment; the end-to-end
  `substitute_all_sections/3` case lives in
  `test/integration/google_docs_client_http_test.exs` alongside its
  existing header/footer substitution coverage (it needs the HTTP stub,
  since `substitute_all_sections/3` has no `:get_fn`/`:batch_fn` opts).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # Regression guard for a real Docs API rule (verified live 2026-09-23,
  # fe631e3): a `deleteContentRange` reaching a segment's own terminal
  # newline is rejected outright — "Invalid requests[N].deleteContentRange:
  # The range cannot include the newline character at the end of the
  # segment" — failing the WHOLE batch and leaving the append half-done.
  # Mocks accept any range unconditionally, so nothing else here would
  # catch a regression back to that shape. `terminal_index` is the
  # segment's own known length at that point in the test's fixture (its
  # length never changes here — nothing after this point inserts/deletes
  # segment-scoped content in the batches this checks).
  defp refute_terminal_newline_delete!(requests, terminal_index) do
    refute Enum.any?(requests, fn
             %{"deleteContentRange" => %{"range" => %{"endIndex" => ^terminal_index}}} -> true
             _ -> false
           end),
           "deleteContentRange must never reach a segment's own terminal newline " <>
             "(index #{terminal_index}) — the Docs API rejects it"
  end

  defp text_paragraph(text),
    do: %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => text}}]}}

  defp table_header_content do
    [
      %{
        "table" => %{
          "rows" => 1,
          "columns" => 1,
          "tableRows" => [
            %{
              "tableCells" => [
                %{
                  "content" => [
                    %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Reg\n"}}]}}
                  ]
                }
              ]
            }
          ]
        }
      }
    ]
  end

  # Body content shared by most tests below: one existing paragraph ending
  # at index 10 (same numbers as google_docs_client_append_tables_test.exs's
  # fixtures) so insert_index=9, content_start=11, break_index=10 — no
  # table in the BODY, so `finish_append_template/6` never re-fetches,
  # keeping the `:counters` sequence in every test about the HEADER/FOOTER
  # re-fetches only.
  defp target_body do
    %{
      "content" => [
        %{
          "paragraph" => %{
            "elements" => [
              %{"startIndex" => 1, "endIndex" => 10, "textRun" => %{"content" => "Existing\n"}}
            ]
          }
        }
      ]
    }
  end

  describe "append_template/3 — template has no header/footer at all (regression)" do
    test "no createHeader/createFooter, no extra get_fn calls" do
      template_doc = %{"body" => %{"content" => [text_paragraph("Body\n")]}}
      current_doc = %{"body" => target_body()}

      get_calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          :counters.add(get_calls, 1, 1)
          {:ok, %{body: current_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      refute_receive {:batch, _}
      assert :counters.get(get_calls, 1) == 1
    end
  end

  describe "append_template/3 — template's header fingerprints the same as what the section would inherit" do
    test "no createHeader, no extra get_fn calls" do
      shared_header_content = [text_paragraph("Hi\n")]

      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => shared_header_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => shared_header_content}},
        "body" => target_body()
      }

      get_calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          :counters.add(get_calls, 1, 1)
          {:ok, %{body: current_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      refute_receive {:batch, _}
      assert :counters.get(get_calls, 1) == 1
    end
  end

  describe "append_template/3 — template's header differs from what the section would inherit" do
    test "creates the header at the section's own break and replays its (table-free) content" do
      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => [text_paragraph("Hi\n")]}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => [text_paragraph("Bye\n")]}},
        "body" => target_body()
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}

      assert_receive {:batch,
                      [
                        %{
                          "createHeader" => %{
                            "type" => "DEFAULT",
                            "sectionBreakLocation" => %{"index" => 10}
                          }
                        }
                      ]}

      assert_receive {:batch, [insert_req, para_req, text_req]}

      # "Hi\n"'s own trailing newline is stripped before insertion — the
      # fresh segment's pre-existing one serves as its terminator instead
      # (the Docs API refuses to delete a segment's terminal newline). The
      # style requests still target the FULL, un-stripped span [0, 3) —
      # covering "Hi" plus that pre-existing newline landing right after it.
      assert insert_req == %{
               "insertText" => %{
                 "location" => %{"index" => 0, "segmentId" => "kix.new_header"},
                 "text" => "Hi"
               }
             }

      assert para_req["updateParagraphStyle"]["range"] == %{
               "startIndex" => 0,
               "endIndex" => 3,
               "segmentId" => "kix.new_header"
             }

      assert text_req["updateTextStyle"]["range"] == %{
               "startIndex" => 0,
               "endIndex" => 3,
               "segmentId" => "kix.new_header"
             }

      # no footer in the template — nothing else follows.
      refute_receive {:batch, _}
    end
  end

  describe "append_template/3 — a section's own header shadows what its trailing section would otherwise chain-inherit" do
    test "the target's LAST section's own header wins over documentStyle's, even when the template matches documentStyle's" do
      # current_doc already has two sections (as if a prior append already
      # gave section 1 its own, different header) — section 0 (and
      # documentStyle) carry "kix.home", section 1 carries its own
      # "kix.landscape_header". A new section whose template's header
      # fingerprints the same as "kix.home" must still get its own replayed
      # copy, because what it'd actually inherit is section 1's, not
      # documentStyle's.
      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => [text_paragraph("Hi\n")]}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.home"},
        "headers" => %{
          "kix.home" => %{"content" => [text_paragraph("Hi\n")]},
          "kix.landscape_header" => %{"content" => [text_paragraph("Landscape\n")]}
        },
        "body" => %{
          "content" => [
            %{"sectionBreak" => %{"sectionStyle" => %{}}},
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "endIndex" => 5, "textRun" => %{"content" => "Sec0\n"}}
                ]
              }
            },
            %{
              "startIndex" => 5,
              "sectionBreak" => %{
                "sectionStyle" => %{"defaultHeaderId" => "kix.landscape_header"}
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 6, "endIndex" => 10, "textRun" => %{"content" => "Sec1\n"}}
                ]
              }
            }
          ]
        }
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}

      assert_receive {:batch,
                      [%{"createHeader" => %{"sectionBreakLocation" => %{"index" => 10}}}]}

      # "Hi\n"'s own trailing newline is stripped — the fresh segment's
      # pre-existing one serves as its terminator (the Docs API refuses to
      # delete a segment's terminal newline).
      assert_receive {:batch, [%{"insertText" => %{"text" => "Hi"}} | _]}
      refute_receive {:batch, _}
    end
  end

  describe "append_template/3 — replays a table inside the new header" do
    test "creates the header, inserts the skeleton, then rebuilds and fills the table via a re-fetch cycle" do
      template_header_content = table_header_content()

      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => template_header_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      {marker_text, _tables} =
        GoogleDocsClient.flatten_template_with_table_markers(%{
          "body" => %{"content" => template_header_content}
        })

      # State after the skeleton insertText: the header segment holds only
      # the marker text.
      doc_after_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [%{"startIndex" => 0, "textRun" => %{"content" => marker_text}}]
                }
              }
            ]
          }
        }
      }

      # State after the table-skeleton batch: the marker is gone, replaced
      # by a bare 1x1 table — but `insertTable` landing where the marker
      # was also split the paragraph that absorbed it, leaving an empty,
      # unstyled phantom paragraph immediately ahead of the table (seen
      # live 2026-09-23 — see `finish_segment_tables/4`'s doc).
      doc_after_table_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "startIndex" => 0,
                "endIndex" => 1,
                "paragraph" => %{
                  "elements" => [
                    %{"startIndex" => 0, "endIndex" => 1, "textRun" => %{"content" => "\n"}}
                  ]
                }
              },
              %{
                "startIndex" => 1,
                "table" => %{
                  "tableRows" => [%{"tableCells" => [%{"startIndex" => 2, "content" => []}]}]
                }
              }
            ]
          }
        }
      }

      # State after the phantom is deleted: the table's index shifts back
      # by the phantom's one character.
      doc_after_phantom_removal = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "startIndex" => 0,
                "table" => %{
                  "tableRows" => [%{"tableCells" => [%{"startIndex" => 1, "content" => []}]}]
                }
              }
            ]
          }
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
            0 -> {:ok, %{body: current_doc}}
            1 -> {:ok, %{body: doc_after_skeleton}}
            2 -> {:ok, %{body: doc_after_table_skeleton}}
            3 -> {:ok, %{body: doc_after_phantom_removal}}
          end
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      assert_receive {:batch, [%{"createHeader" => _}]}

      assert_receive {:batch,
                      [
                        %{
                          "insertText" => %{
                            "location" => %{"segmentId" => "kix.new_header"},
                            "text" => ^marker_text
                          }
                        }
                      ]}

      assert_receive {:batch, table_skeleton_batch}

      assert Enum.any?(
               table_skeleton_batch,
               &match?(%{"insertTable" => %{"rows" => 1, "columns" => 1}}, &1)
             )

      assert Enum.all?(table_skeleton_batch, fn
               %{"deleteContentRange" => %{"range" => range}} ->
                 range["segmentId"] == "kix.new_header"

               %{"insertTable" => %{"location" => loc}} ->
                 loc["segmentId"] == "kix.new_header"
             end)

      assert_receive {:batch,
                      [
                        %{
                          "deleteContentRange" => %{
                            "range" => %{
                              "startIndex" => 0,
                              "endIndex" => 1,
                              "segmentId" => "kix.new_header"
                            }
                          }
                        }
                      ]}

      assert_receive {:batch, fill_batch}
      insert_text = Enum.find(fill_batch, &Map.has_key?(&1, "insertText"))
      # trailing newline stripped — the target's own pre-existing bare cell
      # already supplies it structurally (same convention as the body table
      # fill's `cell_fill_requests/4`, see `cell_text/1`'s doc).
      assert insert_text["insertText"]["text"] == "Reg"
      assert insert_text["insertText"]["location"]["index"] == 2
      assert insert_text["insertText"]["location"]["segmentId"] == "kix.new_header"

      cell_style = Enum.find(fill_batch, &Map.has_key?(&1, "updateTableCellStyle"))

      assert cell_style["updateTableCellStyle"]["tableRange"]["tableCellLocation"][
               "tableStartLocation"
             ] ==
               %{"index" => 0, "segmentId" => "kix.new_header"}

      refute_receive {:batch, _}
    end
  end

  describe "append_template/3 — extra style pass (border/font-family/underline/link)" do
    test "reproduces a rebuilt rule paragraph's border and a link run's font-family/underline/link" do
      rule_border = %{
        "color" => %{"color" => %{"rgbColor" => %{"red" => 0.45}}},
        "dashStyle" => "SOLID",
        "padding" => %{"magnitude" => 1, "unit" => "PT"},
        "width" => %{"magnitude" => 0.75, "unit" => "PT"}
      }

      template_footer_content = [
        %{
          "paragraph" => %{
            "elements" => [%{"textRun" => %{"content" => "\n"}}],
            "paragraphStyle" => %{"borderBottom" => rule_border}
          }
        },
        %{
          "paragraph" => %{
            "elements" => [
              %{
                "textRun" => %{
                  "content" => "Link\n",
                  "textStyle" => %{
                    "weightedFontFamily" => %{"fontFamily" => "Calibri", "weight" => 400},
                    "underline" => true,
                    "link" => %{"url" => "http://example.test"}
                  }
                }
              }
            ]
          }
        }
      ]

      template_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.tpl_footer"},
        "headers" => %{},
        "footers" => %{"kix.tpl_footer" => %{"content" => template_footer_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.cur_footer"},
        "footers" => %{"kix.cur_footer" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn
        "target-id", [%{"createFooter" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createFooter" => %{"footerId" => "kix.new_footer"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      assert_receive {:batch, [%{"createFooter" => _}]}
      assert_receive {:batch, skeleton_batch}
      refute_receive {:batch, _}

      # "Link\n"'s own trailing newline is stripped — the fresh segment's
      # pre-existing one serves as its terminator (the Docs API refuses to
      # delete a segment's terminal newline).
      assert Enum.any?(
               skeleton_batch,
               &match?(
                 %{"insertText" => %{"location" => %{"index" => 0}, "text" => "\nLink"}},
                 &1
               )
             )

      border_request =
        Enum.find(skeleton_batch, fn
          %{"updateParagraphStyle" => %{"paragraphStyle" => %{"borderBottom" => _}}} -> true
          _ -> false
        end)

      assert border_request["updateParagraphStyle"]["range"] == %{
               "startIndex" => 0,
               "endIndex" => 1,
               "segmentId" => "kix.new_footer"
             }

      assert border_request["updateParagraphStyle"]["paragraphStyle"] == %{
               "borderBottom" => rule_border
             }

      assert border_request["updateParagraphStyle"]["fields"] == "borderBottom"

      link_request =
        Enum.find(skeleton_batch, fn
          %{"updateTextStyle" => %{"textStyle" => %{"link" => _}}} -> true
          _ -> false
        end)

      assert link_request["updateTextStyle"]["range"] == %{
               "startIndex" => 1,
               "endIndex" => 6,
               "segmentId" => "kix.new_footer"
             }

      assert link_request["updateTextStyle"]["textStyle"] == %{
               "weightedFontFamily" => %{"fontFamily" => "Calibri", "weight" => 400},
               "underline" => true,
               "link" => %{"url" => "http://example.test"}
             }

      # last block is a plain paragraph, and its own trailing newline was
      # never inserted — the segment's own pre-existing terminal newline
      # (now at index 6: 5 inserted chars + the 1 pre-existing) is never
      # targeted by a delete.
      refute_terminal_newline_delete!(skeleton_batch, 6)
    end

    test "a native horizontalRule replays as a forced 4pt/6pt-spaceBelow bordered paragraph" do
      template_footer_content = [
        %{
          "paragraph" => %{
            "elements" => [
              %{
                "horizontalRule" => %{
                  "textStyle" => %{"fontSize" => %{"magnitude" => 9.5, "unit" => "PT"}}
                }
              },
              %{
                "textRun" => %{
                  "content" => "\n",
                  "textStyle" => %{"fontSize" => %{"magnitude" => 9.5, "unit" => "PT"}}
                }
              }
            ]
          }
        }
      ]

      template_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.tpl_footer"},
        "footers" => %{"kix.tpl_footer" => %{"content" => template_footer_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.cur_footer"},
        "footers" => %{"kix.cur_footer" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn
        "target-id", [%{"createFooter" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createFooter" => %{"footerId" => "kix.new_footer"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      assert_receive {:batch, [%{"createFooter" => _}]}
      assert_receive {:batch, skeleton_batch}
      refute_receive {:batch, _}

      border_request =
        Enum.find(skeleton_batch, fn
          %{"updateParagraphStyle" => %{"paragraphStyle" => %{"borderBottom" => _}}} -> true
          _ -> false
        end)

      assert border_request["updateParagraphStyle"]["paragraphStyle"]["borderBottom"]["width"] ==
               %{"magnitude" => 0.75, "unit" => "PT"}

      assert border_request["updateParagraphStyle"]["paragraphStyle"]["spaceBelow"] ==
               %{"magnitude" => 6.0, "unit" => "PT"}

      font_size_requests =
        Enum.filter(skeleton_batch, fn
          %{"updateTextStyle" => %{"textStyle" => %{"fontSize" => _}}} -> true
          _ -> false
        end)

      # the run's own fontSize is ALSO captured by the shared narrow pass
      # (9.5pt, its own request earlier in the batch) — the extra pass's
      # own request, LAST in the batch, overrides it to the forced 4pt.
      assert List.last(font_size_requests)["updateTextStyle"]["textStyle"]["fontSize"] ==
               %{"magnitude" => 4.0, "unit" => "PT"}
    end
  end

  describe "header_footer_owners/3" do
    defp section(position, values),
      do: %{position: position, variable_values: values, image_params: %{}}

    test "every section sharing the one original segment owns it via the lowest position (regression)" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.home", "defaultFooterId" => "kix.foot"},
        "body" => %{
          "content" => [
            %{"sectionBreak" => %{"sectionStyle" => %{}}},
            %{"paragraph" => %{}},
            %{"startIndex" => 5, "sectionBreak" => %{"sectionStyle" => %{}}},
            %{"paragraph" => %{}}
          ]
        }
      }

      sections = [section(0, %{"a" => "A"}), section(1, %{"a" => "should-not-win"})]
      ranges = %{0 => {1, 5}, 1 => {6, 10}}

      owners = GoogleDocsClient.header_footer_owners(doc, sections, ranges)

      assert owners["kix.home"] == section(0, %{"a" => "A"})
      assert owners["kix.foot"] == section(0, %{"a" => "A"})
    end

    test "a section that creates its own header/footer owns that segment id" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.home"},
        "body" => %{
          "content" => [
            %{"sectionBreak" => %{"sectionStyle" => %{}}},
            %{"paragraph" => %{}},
            %{
              "startIndex" => 5,
              "sectionBreak" => %{"sectionStyle" => %{"defaultHeaderId" => "kix.own"}}
            },
            %{"paragraph" => %{}}
          ]
        }
      }

      sections = [section(0, %{"title" => "Home"}), section(1, %{"title" => "Section 1"})]
      ranges = %{0 => {1, 5}, 1 => {6, 10}}

      owners = GoogleDocsClient.header_footer_owners(doc, sections, ranges)

      assert owners["kix.home"] == section(0, %{"title" => "Home"})
      assert owners["kix.own"] == section(1, %{"title" => "Section 1"})
    end
  end
end
