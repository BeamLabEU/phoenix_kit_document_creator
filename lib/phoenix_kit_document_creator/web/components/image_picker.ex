defmodule PhoenixKitDocumentCreator.Web.Components.ImagePicker do
  @moduledoc """
  Generic image picker LiveComponent.

  Inputs (assigns):
    * `:id` — required
    * `:picker_id` — required `String.t()`; echoed back to the host in every
      change message so a single LiveView can host multiple pickers
    * `:scope_type` — opaque string (used by the host to resolve files)
    * `:scope_id` — opaque string (used by the host to resolve files)
    * `:mode` — `:single` or `:list`
    * `:current_selection` — `[file_uuid]` (OPTIONAL). Selection mode contract:
      - If the host wants to control selection externally, it MUST echo back
        the latest selection on every render (e.g. on receipt of the
        `:image_picker_changed` message). Otherwise an unrelated host re-render
        would clobber internal state.
      - If the host omits `:current_selection`, the component manages
        selection internally via `assign_new/2` (default `[]`).
    * `:files` — `[%{uuid: String.t(), name: String.t(), url: String.t()}]`
      provided by the host (host resolves storage scope to files)

  Output: on selection change the component calls
    `send(self(), {:image_picker_changed, picker_id, selection})`
  The host LiveView must implement `handle_info({:image_picker_changed, _, _}, socket)`.
  """
  use Phoenix.LiveComponent

  @page_size 50

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:current_selection, fn -> [] end)
      |> assign_new(:filter, fn -> "" end)
      |> assign_new(:page, fn -> 0 end)
      |> compute_visible()

    {:ok, socket}
  end

  defp compute_visible(socket) do
    %{filter: q, page: page, files: files} = socket.assigns

    filtered =
      if q == "",
        do: files,
        else: Enum.filter(files, &String.contains?(String.downcase(&1.name), String.downcase(q)))

    visible = filtered |> Enum.drop(page * @page_size) |> Enum.take(@page_size)
    assign(socket, filtered_count: length(filtered), visible: visible)
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"q" => q}}, socket) do
    {:noreply, socket |> assign(filter: q, page: 0) |> compute_visible()}
  end

  def handle_event("next-page", _, socket) do
    max_page = div(socket.assigns.filtered_count - 1, @page_size)
    page = min(socket.assigns.page + 1, max(0, max_page))
    {:noreply, socket |> assign(page: page) |> compute_visible()}
  end

  def handle_event("prev-page", _, socket) do
    {:noreply, socket |> assign(page: max(0, socket.assigns.page - 1)) |> compute_visible()}
  end

  def handle_event("pick", %{"uuid" => uuid}, socket) do
    sel = socket.assigns.current_selection

    new =
      case socket.assigns.mode do
        :single ->
          if sel == [uuid], do: [], else: [uuid]

        :list ->
          if uuid in sel,
            do: Enum.reject(sel, &(&1 == uuid)),
            else: Enum.uniq(sel ++ [uuid])
      end

    notify(socket, new)
    {:noreply, assign(socket, current_selection: new)}
  end

  def handle_event("remove", %{"uuid" => uuid}, socket) do
    new = Enum.reject(socket.assigns.current_selection, &(&1 == uuid))
    notify(socket, new)
    {:noreply, assign(socket, current_selection: new)}
  end

  def handle_event("clear", _params, socket) do
    notify(socket, [])
    {:noreply, assign(socket, current_selection: [])}
  end

  defp notify(%{assigns: %{picker_id: picker_id}}, sel) do
    send(self(), {:image_picker_changed, picker_id, sel})
    :ok
  end

  defp file_name(files, uuid) do
    case Enum.find(files, &(&1.uuid == uuid)) do
      nil -> uuid
      f -> f.name
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-3">
      <%!-- Selected chips --%>
      <%= if @current_selection != [] do %>
        <div class="flex flex-wrap gap-1.5 p-2 bg-base-200 rounded-lg">
          <div
            :for={uuid <- @current_selection}
            class="badge badge-primary gap-1 max-w-[200px]"
          >
            <span class="truncate text-xs" title={file_name(@files, uuid)}>
              {file_name(@files, uuid)}
            </span>
            <button
              type="button"
              phx-click="remove"
              phx-value-uuid={uuid}
              phx-target={@myself}
              class="hover:opacity-70 flex-shrink-0 ml-0.5"
              title="Убрать"
            >
              &times;
            </button>
          </div>
          <button
            :if={@mode == :single}
            type="button"
            phx-click="clear"
            phx-target={@myself}
            class="badge badge-ghost text-xs"
          >
            Сбросить
          </button>
        </div>
      <% end %>

      <%!-- Filter --%>
      <.form
        for={%{}}
        as={:filter}
        id={"image-picker-filter-#{@id}"}
        phx-change="filter"
        phx-target={@myself}
      >
        <input
          name="filter[q]"
          value={@filter}
          placeholder="Поиск по имени"
          class="input input-sm input-bordered w-full"
        />
      </.form>

      <%!-- Image grid --%>
      <%= if @visible == [] do %>
        <div class="text-sm text-base-content/50 text-center py-4">Файлы не найдены</div>
      <% else %>
        <div class="grid grid-cols-3 sm:grid-cols-4 gap-2">
          <button
            :for={f <- @visible}
            type="button"
            phx-click="pick"
            phx-value-uuid={f.uuid}
            phx-target={@myself}
            title={f.name}
            class={[
              "relative flex flex-col items-center gap-1 p-2 rounded-lg border-2 transition-colors",
              "hover:bg-base-200 focus:outline-none",
              if(f.uuid in @current_selection,
                do: "border-primary bg-primary/10",
                else: "border-base-300 bg-base-100"
              )
            ]}
          >
            <span
              :if={f.uuid in @current_selection}
              class="absolute top-1 right-1 w-4 h-4 bg-primary text-primary-content rounded-full text-[10px] flex items-center justify-center font-bold leading-none"
            >
              ✓
            </span>
            <img src={f.url} alt={f.name} class="w-full h-16 object-contain" />
            <span class="text-[11px] text-center leading-tight w-full line-clamp-2 break-words">
              {f.name}
            </span>
          </button>
        </div>
      <% end %>

      <%!-- Pagination --%>
      <div class="flex items-center justify-between">
        <button
          type="button"
          phx-click="prev-page"
          phx-target={@myself}
          class="btn btn-xs btn-ghost"
          disabled={@page == 0}
        >
          &lsaquo; Назад
        </button>
        <span class="text-xs text-base-content/60">
          {@page + 1} / {max(1, div(@filtered_count - 1, @page_size) + 1)}
          &nbsp;({@filtered_count} файл.)
        </span>
        <button
          type="button"
          phx-click="next-page"
          phx-target={@myself}
          class="btn btn-xs btn-ghost"
          disabled={@page + 1 >= max(1, div(@filtered_count - 1, @page_size) + 1)}
        >
          Вперёд &rsaquo;
        </button>
      </div>
    </div>
    """
  end
end
