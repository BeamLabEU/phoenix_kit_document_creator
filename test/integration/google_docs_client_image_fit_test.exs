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

      # box_w = 451.28pt; avail_h = 697.89 - 60 (default safety, no preceding
      # paragraphs) = 637.89pt. scale = min(451.28/1600, 637.89/900) → width wins.
      assert_in_delta width, 451.28, 0.01
      assert_in_delta height, 900 * (451.28 / 1600), 0.01
      assert height < 637.89
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
      avail_h = 697.89 - 60.0

      assert_in_delta height, avail_h, 0.01
      assert width < 451.28
    end

    test "reserve is the estimated height of the section's 3 preceding paragraphs, plus the safety margin" do
      # 3 empty (default-style) paragraphs before the slot: each contributes
      # 11pt * 1.15 = 12.65pt → 37.95pt total, plus the default safety margin (60pt).
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

      expected_avail_h = 697.89 - (3 * 12.65 + 60.0)
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

      # avail_h = 697.89 - 200.0 (overridden safety, no preceding paragraphs).
      assert_in_delta height, 697.89 - 200.0, 0.01
    end
  end
end
