defmodule PhoenixKitDocumentCreator.Integration.GoogleDocsClientImageFitTest do
  @moduledoc """
  Coverage for the `fit: "page"` image sizing path and the box-width fix
  (`apply_image_fills/3` reading each slot's own section's `section_boxes/1`
  box instead of the whole document's `content_width_pt/1`) — driven
  end-to-end through `substitute_all_sections/3` the same way the existing
  blank-value / section-shift tests in `google_docs_client_http_test.exs`
  are, so the assertions read off the real `insertInlineImage` request the
  library would send.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Test.StubIntegrations

  # A default-style (11pt / 115% lineSpacing) line's height, including the
  # @font_leading (1.22) multiplier `estimate_paragraph_height_pt/1` applies
  # — used both for a preceding body paragraph's reserve and for
  # `page_fit_trailing_line_pt` (one such line, applied to every fit=page
  # image — see `page_fit_image_list_inserts/4`'s doc).
  @default_line_pt 11.0 * 1.15 * 1.22

  setup do
    previous = Application.get_env(:phoenix_kit_document_creator, :integrations_backend)

    Application.put_env(
      :phoenix_kit_document_creator,
      :integrations_backend,
      StubIntegrations
    )

    StubIntegrations.reset!()
    StubIntegrations.connected!()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
        else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)
    end)

    :ok
  end

  # A4-shaped page, portrait: 595.28 x 841.89pt, default 72pt margins on
  # every side → content box 451.28 x 697.89pt.
  defp doc_style(overrides \\ %{}) do
    Map.merge(
      %{
        "pageSize" => %{
          "width" => %{"magnitude" => 595.28, "unit" => "PT"},
          "height" => %{"magnitude" => 841.89, "unit" => "PT"}
        }
      },
      overrides
    )
  end

  defp section_break(start_index, style \\ %{}) do
    %{"startIndex" => start_index, "sectionBreak" => %{"sectionStyle" => style}}
  end

  defp para(start_index, text) do
    end_index = start_index + String.length(text)

    %{
      "startIndex" => start_index,
      "endIndex" => end_index,
      "paragraph" => %{
        "elements" => [
          %{
            "startIndex" => start_index,
            "endIndex" => end_index,
            "textRun" => %{"content" => text}
          }
        ]
      }
    }
  end

  defp stub_doc_and_batch(doc) do
    StubIntegrations.stub_request(:get, "/v1/documents/fit-doc", {:ok, %{status: 200, body: doc}})

    StubIntegrations.stub_request(
      :post,
      ":batchUpdate",
      {:ok, %{status: 200, body: %{"replies" => []}}}
    )
  end

  defp image_list_slot(overrides) do
    Map.merge(
      %{
        "kind" => "image_list",
        "columns" => 1,
        "media" => [
          %{"uri" => "https://example.test/a.png", "width_px" => 800, "height_px" => 600}
        ]
      },
      overrides
    )
  end

  defp insert_inline_image_requests do
    for {:post, url, opts} <- StubIntegrations.recorded_requests(),
        String.contains?(url, ":batchUpdate"),
        request <- opts[:json].requests,
        Map.has_key?(request, :insertInlineImage),
        do: request
  end

  describe "box-width fix — image_list columns=1, fit: \"width\" (default)" do
    test "uses the LANDSCAPE section's own box width, not the (portrait) document's" do
      doc = %{
        "documentStyle" => Map.put(doc_style(), "flipPageOrientation", true),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => image_list_slot(%{})}}
      ]

      ranges = %{0 => {1, 23}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])

      # 841.89 - 72 - 72 (the flipped/landscape box), not 595.28 - 144.
      assert_in_delta width, 697.89, 0.01
    end

    test "in a 2-section document, a slot in section 2 gets section 2's box, not section 1's" do
      # Section 1: portrait, no flip. Section 2: landscape via its own
      # sectionStyle.flipPageOrientation (doc-level flip stays false).
      # The image tag's textRun starts EXACTLY at section 2's sectionBreak
      # startIndex (3) — the boundary `box_for_index/2` has to get right:
      # box1 is [0, 3), box2 is [3, 25). A `<` → `<=` mutation on
      # box_for_index's end-index check would make box1 ALSO match index 3
      # (and, since boxes are tried in order, win), picking the wrong
      # (portrait) box — this test fails under that mutation (verified
      # manually before committing).
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            %{
              "startIndex" => 1,
              "endIndex" => 3,
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "endIndex" => 3, "textRun" => %{"content" => "x\n"}}
                ]
              }
            },
            section_break(3, %{"flipPageOrientation" => true}),
            %{
              "startIndex" => 3,
              "endIndex" => 25,
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 3,
                    "endIndex" => 25,
                    "textRun" => %{"content" => "{{ images: photos }}\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      stub_doc_and_batch(doc)

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => image_list_slot(%{})}}
      ]

      ranges = %{0 => {1, 25}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      # Section 2's (landscape) box: 841.89 - 144 wide, 595.28 - 144 tall —
      # NOT section 1's (portrait) 451.28 x 697.89. Height follows the
      # slot's default media aspect (800x600 — see image_list_slot/1),
      # scaled from the section-2 width; scale_height/3 rounds to an
      # integer PT value, hence the wider delta.
      assert_in_delta width, 697.89, 0.01
      assert_in_delta height, 697.89 * 600 / 800, 1.0
    end
  end

  describe "fit: \"page\" — scale = min(box_w / w_px, avail_h / h_px)" do
    test "a horizontal image is bound by width" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 1600, "height_px" => 900}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 23}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      # box_w = 451.28pt; no header/footer content → body_top_pt = marginTop
      # (72), body_bottom_pt = pageH - marginBottom (841.89 - 72 = 769.89).
      # avail_h = 769.89 - 72 - @default_line_pt (trailing line) - 8.0
      # (default safety, no preceding paragraphs).
      # scale = min(451.28/1600, avail_h/900) → width wins.
      avail_h = 769.89 - 72 - @default_line_pt - 8.0
      assert_in_delta width, 451.28, 0.01
      assert_in_delta height, 900 * (451.28 / 1600), 0.01
      assert height < avail_h
    end

    test "a vertical image is bound by height" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 900, "height_px" => 1600}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 23}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])
      # See the horizontal-image test above for the avail_h derivation.
      avail_h = 769.89 - 72 - @default_line_pt - 8.0

      assert_in_delta height, avail_h, 0.01
      assert width < 451.28
    end

    test "reserve is the estimated height of the section's 3 preceding paragraphs, plus the safety margin" do
      # 3 empty (default-style) paragraphs before the slot: each contributes
      # @default_line_pt → 3 * @default_line_pt total. No header content, so
      # body_top_pt = marginTop (72); the paragraphs push the first image's
      # start to marginTop + 3 * @default_line_pt (> body_top_pt, so it wins
      # the `max`). avail_h = body_bottom_pt (769.89) - that start -
      # @default_line_pt (trailing line) - 8.0 (default safety).
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            para(1, "\n"),
            para(2, "\n"),
            para(3, "\n"),
            para(4, "{{ images: photos }}\n")
          ]
        }
      }

      stub_doc_and_batch(doc)

      # Extreme aspect ratio so the fit is unambiguously height-bound —
      # the resulting height pins down avail_h (and thus the reserve).
      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 100, "height_px" => 1000}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 27}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      expected_avail_h = 769.89 - (72 + 3 * @default_line_pt) - @default_line_pt - 8.0
      assert_in_delta height, expected_avail_h, 0.01
    end

    test "two images in one fit=page slot: safety applies to BOTH, paragraphs-reserve only to the first" do
      # One preceding paragraph (@default_line_pt) before the slot. First (topmost,
      # rendered-order) image loses safety AND the paragraph reserve;
      # second image loses only safety — see page_fit_image_list_inserts/4's
      # doc. A regression to "safety only for the first image" (the
      # pre-4ea345b behavior) would give the second image the full box
      # height instead, failing the second assertion below (verified by
      # hand against that mutation before committing).
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            para(1, "\n"),
            para(2, "{{ images: photos }}\n")
          ]
        }
      }

      stub_doc_and_batch(doc)

      # Extreme aspect ratio (both images) so the fit is unambiguously
      # height-bound — the resulting height pins down each image's avail_h.
      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [
            %{"uri" => "a", "width_px" => 100, "height_px" => 1000},
            %{"uri" => "b", "width_px" => 100, "height_px" => 1000}
          ]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 24}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      inserts = insert_inline_image_requests()
      by_uri = Map.new(inserts, fn req -> {req.insertInlineImage.uri, req} end)

      first_height = get_in(by_uri["a"], [:insertInlineImage, :objectSize, :height, :magnitude])
      second_height = get_in(by_uri["b"], [:insertInlineImage, :objectSize, :height, :magnitude])

      # First (uri "a", first rendered): body_bottom_pt - start - trailing -
      # safety, start = max(body_top_pt=72, marginTop + reserve).
      first_start = max(72, 72 + @default_line_pt)
      expected_first = 769.89 - first_start - @default_line_pt - 8.0
      # Second (uri "b"): starts at body_top_pt (72) — NOT the full box height.
      expected_second = 769.89 - 72 - @default_line_pt - 8.0

      assert_in_delta first_height, expected_first, 0.01
      assert_in_delta second_height, expected_second, 0.01
      assert second_height < 697.89
    end

    test "a header taller than its margin wins the max() against a small paragraphs-reserve — not their sum" do
      # Header extent: 6 default-style lines (6 * @default_line_pt) +
      # marginHeader (36, default) — comfortably over marginTop + the one
      # preceding body paragraph's reserve (72 + @default_line_pt).
      # body_top_pt should win the `max`. A `max` → `+` mutation on the first
      # image's start would SUM body_top_pt and (marginTop + reserve) instead
      # of taking the larger one, badly undersizing avail_h — this test fails
      # under that mutation (verified by hand before committing).
      header_lines =
        for _ <- 1..6,
            do: %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "\n"}}]}}

      doc = %{
        "documentStyle" => Map.merge(doc_style(), %{"defaultHeaderId" => "h1"}),
        "headers" => %{"h1" => %{"content" => header_lines}},
        "body" => %{
          "content" => [
            section_break(0),
            para(1, "\n"),
            para(2, "{{ images: photos }}\n")
          ]
        }
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 100, "height_px" => 1000}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 24}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      # body_top_pt = max(72, 36 + 6 * @default_line_pt) — the header wins.
      # marginTop + paragraphs_reserve (72 + @default_line_pt) is smaller,
      # loses the max(). start = body_top_pt (NOT their sum).
      body_top_pt = 36.0 + 6 * @default_line_pt
      expected_avail_h = 769.89 - body_top_pt - @default_line_pt - 8.0

      assert_in_delta height, expected_avail_h, 0.01
    end
  end

  describe "fit=page scope guards — fall back to fit=width and warn" do
    test "columns >= 2 is out of scope" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "columns" => 2,
          "media" => [%{"uri" => "a"}, %{"uri" => "b"}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 23}}

      log =
        capture_log(fn ->
          assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)
        end)

      assert log =~ "fit=page ignored for image slot \"photos\""
      assert log =~ "columns >= 2 is out of scope"

      table_requests =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            request <- opts[:json].requests,
            Map.has_key?(request, "insertTable"),
            do: request

      assert [_] = table_requests
    end

    test "a slot inside a table cell is out of scope" do
      # The tag lives inside a pre-existing table cell in the template's own
      # content (not one this library creates for a columns >= 2 slot).
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            %{
              "startIndex" => 1,
              "endIndex" => 60,
              "table" => %{
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "startIndex" => 3,
                        "content" => [para(4, "{{ images: photos }}\n")]
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
      }

      stub_doc_and_batch(doc)

      slot = image_list_slot(%{"fit" => "page"})

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {0, 60}}

      log =
        capture_log(fn ->
          assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)
        end)

      assert log =~ "fit=page ignored for image slot \"photos\""
      assert log =~ "sits inside a table cell"

      # No explicit sectionBreak → section_boxes/1 falls back to a single
      # box for the whole body, still using documentStyle's own pageSize —
      # confirms the plain fit: "width" path ran, not the page-fit scale
      # formula (which would have been height-bound and much narrower).
      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])
      assert_in_delta width, 451.28, 0.01
    end

    test "a second fit: \"page\" slot in the same section falls back to width" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            para(1, "{{ images: first }}\n"),
            para(22, "{{ images: second }}\n")
          ]
        }
      }

      stub_doc_and_batch(doc)

      first_slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "a", "width_px" => 900, "height_px" => 1600}]
        })

      second_slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "b", "width_px" => 900, "height_px" => 1600}]
        })

      sections = [
        %{
          position: 0,
          variable_values: %{},
          image_params: %{"first" => first_slot, "second" => second_slot}
        }
      ]

      ranges = %{0 => {1, 43}}

      log =
        capture_log(fn ->
          assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)
        end)

      assert log =~ "fit=page ignored for image slot \"second\""
      assert log =~ "already has a fit=page slot"

      inserts = insert_inline_image_requests()
      by_uri = Map.new(inserts, fn req -> {req.insertInlineImage.uri, req} end)

      first_height = get_in(by_uri["a"], [:insertInlineImage, :objectSize, :height, :magnitude])
      second_width = get_in(by_uri["b"], [:insertInlineImage, :objectSize, :width, :magnitude])

      # First slot got the real page-fit treatment (height-bound, < full box).
      assert first_height < 697.89
      # Second slot fell back to fit: "width" — full box width.
      assert_in_delta second_width, 451.28, 0.01
    end
  end

  describe "page_fit_safety_pt/0 — host-tunable via config" do
    setup do
      previous = Application.get_env(:phoenix_kit_document_creator, :page_fit_safety_pt)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit_document_creator, :page_fit_safety_pt, previous),
          else: Application.delete_env(:phoenix_kit_document_creator, :page_fit_safety_pt)
      end)

      :ok
    end

    test "an env override changes the reserve applied to a fit: \"page\" image" do
      Application.put_env(:phoenix_kit_document_creator, :page_fit_safety_pt, 200.0)

      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 100, "height_px" => 1000}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 23}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      # avail_h = 769.89 (body_bottom_pt) - 72 (start) - @default_line_pt
      # (trailing line) - 200.0 (overridden safety, no preceding paragraphs).
      assert_in_delta height, 769.89 - 72 - @default_line_pt - 200.0, 0.01
    end
  end
end
