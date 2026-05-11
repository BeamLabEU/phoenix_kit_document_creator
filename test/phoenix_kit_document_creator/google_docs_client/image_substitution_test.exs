defmodule PhoenixKitDocumentCreator.GoogleDocsClient.ImageSubstitutionTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # Mimics a minimal Google Docs JSON response.
  defp doc_with_text(text, start_index \\ 1) do
    %{
      "body" => %{
        "content" => [
          %{
            "paragraph" => %{
              "elements" => [
                %{
                  "startIndex" => start_index,
                  "endIndex" => start_index + String.length(text),
                  "textRun" => %{"content" => text}
                }
              ]
            }
          }
        ]
      }
    }
  end

  describe "find_image_tag_ranges/2" do
    test "finds a single tag in body" do
      doc = doc_with_text("Logo: {{ image: logo }} done", 1)

      assert GoogleDocsClient.find_image_tag_ranges(doc, ["logo"]) == [
               %{
                 name: "logo",
                 start_index: 7,
                 end_index: 24
               }
             ]
    end

    test "finds the same tag in multiple positions" do
      doc = doc_with_text("A {{ image: x }} B {{ image: x }} C", 1)
      ranges = GoogleDocsClient.find_image_tag_ranges(doc, ["x"])
      assert length(ranges) == 2
      assert Enum.all?(ranges, &(&1.name == "x"))
    end

    test "ignores tags not in the requested name list" do
      doc = doc_with_text("{{ image: yes }} {{ image: no }}", 1)
      ranges = GoogleDocsClient.find_image_tag_ranges(doc, ["yes"])
      assert Enum.map(ranges, & &1.name) == ["yes"]
    end

    test "walks into headers" do
      doc = %{
        "body" => %{"content" => []},
        "headers" => %{
          "kix.h1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "startIndex" => 1,
                      "endIndex" => 18,
                      "textRun" => %{"content" => "{{ image: logo }}"}
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      assert [%{name: "logo"}] = GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
    end

    test "walks into footers" do
      doc = %{
        "body" => %{"content" => []},
        "footers" => %{
          "kix.f1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "startIndex" => 1,
                      "endIndex" => 18,
                      "textRun" => %{"content" => "{{ image: logo }}"}
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      assert [%{name: "logo"}] = GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
    end

    test "walks into table cells" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "content" => [
                          %{
                            "paragraph" => %{
                              "elements" => [
                                %{
                                  "startIndex" => 5,
                                  "endIndex" => 22,
                                  "textRun" => %{"content" => "{{ image: logo }}"}
                                }
                              ]
                            }
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
      }

      assert [%{name: "logo", start_index: 5, end_index: 22}] =
               GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
    end
  end
end
