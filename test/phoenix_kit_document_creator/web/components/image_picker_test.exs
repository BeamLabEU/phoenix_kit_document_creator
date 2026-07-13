defmodule PhoenixKitDocumentCreator.Web.Components.ImagePickerTest do
  use PhoenixKitDocumentCreator.LiveCase, async: true

  alias PhoenixKitDocumentCreator.Web.Components.ImagePicker

  @files Enum.map(1..120, fn i ->
           %{uuid: "uuid-#{i}", name: "img-#{i}.png", url: "https://x/#{i}.png"}
         end)

  # Tile buttons render as `phx-click="pick" phx-value-uuid="..."`; the
  # selected tile carries the `border-primary` class.
  defp pick_button(uuid), do: "button[phx-click=pick][phx-value-uuid=#{uuid}]"

  defp selected_regex(uuid) do
    ~r/phx-value-uuid="#{uuid}"[^>]*border-primary/
  end

  test "renders first page of 50 files for :single mode" do
    {:ok, view, _} =
      render_live(ImagePicker, %{
        id: "p",
        picker_id: "order-images",
        scope_type: "order",
        scope_id: "ord-1",
        mode: :single,
        current_selection: [],
        files: @files
      })

    html = render(view)
    assert html =~ "img-1.png"
    assert html =~ "img-50.png"
    refute html =~ "img-51.png"
  end

  test "name filter narrows results" do
    {:ok, view, _} =
      render_live(ImagePicker, %{
        id: "p",
        picker_id: "order-images",
        scope_type: "order",
        scope_id: "ord-1",
        mode: :single,
        current_selection: [],
        files: @files
      })

    view |> form("#image-picker-filter-p", filter: %{q: "img-11"}) |> render_change()
    html = render(view)
    assert html =~ "img-11.png"
    assert html =~ "img-110.png"
    refute html =~ "img-1.png"
  end

  test "single mode emits selection_changed with one uuid and replaces previous" do
    {:ok, view, _} =
      render_live(ImagePicker, %{
        id: "p",
        picker_id: "order-images",
        scope_type: "order",
        scope_id: "ord-1",
        mode: :single,
        current_selection: [],
        files: @files
      })

    view |> element(pick_button("uuid-3")) |> render_click()
    assert_receive {:image_picker_changed, "order-images", ["uuid-3"]}

    view |> element(pick_button("uuid-4")) |> render_click()
    assert_receive {:image_picker_changed, "order-images", ["uuid-4"]}
  end

  test "list mode accumulates selections" do
    {:ok, view, _} =
      render_live(ImagePicker, %{
        id: "p",
        picker_id: "order-images",
        scope_type: "order",
        scope_id: "ord-1",
        mode: :list,
        current_selection: [],
        files: @files
      })

    view |> element(pick_button("uuid-1")) |> render_click()
    view |> element(pick_button("uuid-2")) |> render_click()
    assert_receive {:image_picker_changed, "order-images", ["uuid-1"]}
    assert_receive {:image_picker_changed, "order-images", ["uuid-1", "uuid-2"]}
  end

  test "next page button advances by 50" do
    {:ok, view, _} =
      render_live(ImagePicker, %{
        id: "p",
        picker_id: "order-images",
        scope_type: "order",
        scope_id: "ord-1",
        mode: :single,
        current_selection: [],
        files: @files
      })

    view |> element("button[phx-click=next-page]") |> render_click()
    html = render(view)
    refute html =~ "img-50.png"
    assert html =~ "img-51.png"
    assert html =~ "img-100.png"
  end

  test "host-echoes mode: external current_selection is honoured on every render" do
    {:ok, view, _} =
      render_live(ImagePicker, %{
        id: "p",
        picker_id: "order-images",
        scope_type: "order",
        scope_id: "ord-1",
        mode: :list,
        current_selection: ["uuid-7"],
        files: @files
      })

    assert render(view) =~ selected_regex("uuid-7")

    send(view.pid, {:update, %{current_selection: ["uuid-8"]}})
    assert render(view) =~ selected_regex("uuid-8")
  end

  test "host-omits mode: component manages selection internally across host re-renders" do
    {:ok, view, _} =
      render_live(ImagePicker, %{
        id: "p",
        picker_id: "order-images",
        scope_type: "order",
        scope_id: "ord-1",
        mode: :single,
        files: @files
      })

    view |> element(pick_button("uuid-3")) |> render_click()
    assert_receive {:image_picker_changed, "order-images", ["uuid-3"]}

    send(view.pid, {:update, %{files: @files}})
    assert render(view) =~ selected_regex("uuid-3")
  end
end
