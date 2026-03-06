defmodule PhoenixKitDocumentCreator.Web.HeaderFooterLive do
  @moduledoc """
  Shared list page for headers and footers.

  Uses `live_action` to determine which type to display:
  - `:headers` — lists header designs
  - `:footers` — lists footer designs
  """
  use Phoenix.LiveView

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Paths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       items: [],
       error: nil,
       confirm_delete: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    type = type_from_action(socket.assigns.live_action)
    items = if connected?(socket), do: list_by_type(type), else: []

    {:noreply,
     assign(socket,
       type: type,
       items: items,
       page_title: type_label_plural(type)
     )}
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("confirm_delete", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, confirm_delete: uuid)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: nil)}
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Documents.get_header_footer(uuid) do
      nil ->
        {:noreply, assign(socket, confirm_delete: nil)}

      hf ->
        case Documents.delete_header_footer(hf) do
          {:ok, _} ->
            items = list_by_type(socket.assigns.type)
            {:noreply, assign(socket, items: items, confirm_delete: nil)}

          {:error, _} ->
            {:noreply, assign(socket, error: "Delete failed", confirm_delete: nil)}
        end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp type_from_action(:headers), do: "header"
  defp type_from_action(:footers), do: "footer"

  defp list_by_type("header"), do: Documents.list_headers()
  defp list_by_type("footer"), do: Documents.list_footers()

  defp type_label_plural("header"), do: "Headers"
  defp type_label_plural("footer"), do: "Footers"

  defp type_label_singular("header"), do: "Header"
  defp type_label_singular("footer"), do: "Footer"

  defp type_new_path("header"), do: Paths.header_new()
  defp type_new_path("footer"), do: Paths.footer_new()

  defp type_edit_path("header", uuid), do: Paths.header_edit(uuid)
  defp type_edit_path("footer", uuid), do: Paths.footer_edit(uuid)

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <%!-- Header bar --%>
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <a href={Paths.index()} class="btn btn-ghost btn-sm btn-square">
            <span class="hero-arrow-left w-5 h-5" />
          </a>
          <h1 class="text-xl font-bold">{type_label_plural(@type)}</h1>
        </div>
        <a href={type_new_path(@type)} class="btn btn-primary btn-sm">
          <span class="hero-plus w-4 h-4" /> New {type_label_singular(@type)}
        </a>
      </div>

      <div :if={@error} class="alert alert-error">
        <span class="hero-x-circle w-5 h-5" />
        <span>{@error}</span>
      </div>

      <%!-- Empty state --%>
      <div :if={@items == []} class="card bg-base-100 shadow-xl">
        <div class="card-body items-center text-center py-12">
          <span class="hero-bars-3 w-12 h-12 text-base-content/20" />
          <h3 class="text-lg font-medium mt-2">No {String.downcase(type_label_plural(@type))} yet</h3>
          <p class="text-sm text-base-content/60">
            Create reusable {String.downcase(type_label_singular(@type))} designs that can be assigned to templates.
          </p>
          <a href={type_new_path(@type)} class="btn btn-primary btn-sm mt-4">
            <span class="hero-plus w-4 h-4" /> Create First {type_label_singular(@type)}
          </a>
        </div>
      </div>

      <%!-- List --%>
      <div :if={@items != []} class="space-y-3">
        <div :for={item <- @items} class="card bg-base-100 shadow-sm">
          <div class="card-body p-4 flex-row items-center justify-between">
            <div>
              <h3 class="font-medium">{item.name}</h3>
              <p class="text-xs text-base-content/50">
                Height: {item.height}
                <span class="mx-1">·</span>
                Updated {Calendar.strftime(item.updated_at, "%b %d, %Y")}
              </p>
            </div>
            <div class="flex gap-2">
              <a
                href={type_edit_path(@type, item.uuid)}
                class="btn btn-ghost btn-sm"
              >
                <span class="hero-pencil-square w-4 h-4" /> Edit
              </a>
              <%= if @confirm_delete == item.uuid do %>
                <button
                  class="btn btn-error btn-sm"
                  phx-click="delete"
                  phx-value-uuid={item.uuid}
                >
                  Confirm
                </button>
                <button class="btn btn-ghost btn-sm" phx-click="cancel_delete">
                  Cancel
                </button>
              <% else %>
                <button
                  class="btn btn-ghost btn-sm text-error"
                  phx-click="confirm_delete"
                  phx-value-uuid={item.uuid}
                >
                  <span class="hero-trash w-4 h-4" />
                </button>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
