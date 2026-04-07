defmodule PhoenixKitDocumentCreator.Web.DocumentsLive do
  @moduledoc """
  Main listing page for the Document Creator.

  Lists templates and documents from the local database for fast rendering.
  Background sync keeps the DB in sync with Google Drive. Files that
  disappear from Drive are shown with a "lost" indicator.
  """
  use Phoenix.LiveView

  import PhoenixKitDocumentCreator.Web.Components.CreateDocumentModal

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  @pubsub_topic "document_creator:files"
  @refresh_cooldown_ms :timer.seconds(5)
  @max_pdf_push_bytes 5_000_000

  @impl true
  def mount(_params, _session, socket) do
    google_connected =
      case GoogleDocsClient.connection_status() do
        {:ok, _} -> true
        _ -> false
      end

    # Load from DB immediately (fast, no API call)
    {templates, documents} =
      if google_connected do
        {Documents.list_templates_from_db(), Documents.list_documents_from_db()}
      else
        {[], []}
      end

    # Pre-load cached thumbnails from DB
    all_ids = Enum.map(templates ++ documents, & &1["id"])

    cached_thumbnails =
      if all_ids != [], do: Documents.load_cached_thumbnails(all_ids), else: %{}

    db_empty = templates == [] and documents == []

    if connected?(socket) do
      PhoenixKit.PubSubHelper.subscribe(@pubsub_topic)

      if google_connected do
        send(self(), :sync_from_drive)
        :timer.send_interval(:timer.minutes(2), self(), :poll_for_changes)
      end
    end

    {:ok,
     assign(socket,
       page_title: "Document Creator",
       view_mode: "cards",
       google_connected: google_connected,
       templates: templates,
       documents: documents,
       thumbnails: cached_thumbnails,
       loading: google_connected and db_empty,
       last_loaded_at: nil,
       error: nil,
       # Modal state
       modal_open: false,
       modal_step: "choose",
       modal_selected_template: nil,
       modal_variables: [],
       modal_creating: false
     )}
  end

  # ── Sync from Drive ──────────────────────────────────────────────

  @impl true
  def handle_info(:sync_from_drive, socket) do
    pid = self()

    Task.start(fn ->
      Documents.sync_from_drive()
      send(pid, :sync_complete)
    end)

    {:noreply, socket}
  end

  def handle_info(:sync_complete, socket) do
    templates = Documents.list_templates_from_db()
    documents = Documents.list_documents_from_db()

    # Load cached thumbnails from DB
    all_ids = Enum.map(templates ++ documents, & &1["id"])
    cached_thumbnails = Documents.load_cached_thumbnails(all_ids)

    # Fetch fresh thumbnails for any files missing them
    missing_thumb_files =
      (templates ++ documents)
      |> Enum.filter(fn f -> is_nil(cached_thumbnails[f["id"]]) end)

    if missing_thumb_files != [], do: load_thumbnails_async(missing_thumb_files)

    {:noreply,
     assign(socket,
       templates: templates,
       documents: documents,
       thumbnails: Map.merge(socket.assigns.thumbnails, cached_thumbnails),
       loading: false,
       last_loaded_at: now_ms()
     )}
  end

  def handle_info(:load_thumbnails, socket) do
    load_thumbnails_async(socket.assigns.templates ++ socket.assigns.documents)
    {:noreply, socket}
  end

  def handle_info({:thumbnail_result, file_id, data_uri}, socket) do
    {:noreply, assign(socket, thumbnails: Map.put(socket.assigns.thumbnails, file_id, data_uri))}
  end

  def handle_info(:poll_for_changes, socket) do
    if not socket.assigns.loading and not within_cooldown?(socket) do
      send(self(), :sync_from_drive)
    end

    {:noreply, socket}
  end

  def handle_info({:files_changed, from_pid}, socket) do
    if from_pid != self() and not socket.assigns.loading and not within_cooldown?(socket) do
      send(self(), :sync_from_drive)
    end

    {:noreply, socket}
  end

  defp load_thumbnails_async(files) do
    Documents.fetch_thumbnails_async(files, self())
  end

  # ── View toggle ──────────────────────────────────────────────────

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, view_mode: mode)}
  end

  # ── Create actions ───────────────────────────────────────────────

  def handle_event("new_template", _params, socket) do
    case Documents.create_template() do
      {:ok, %{url: url}} ->
        broadcast_files_changed()
        {:noreply, push_event(socket, "open-url", %{url: url})}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to create template: #{inspect(reason)}")}
    end
  end

  def handle_event("new_blank_document", _params, socket) do
    case Documents.create_document() do
      {:ok, %{url: url}} ->
        broadcast_files_changed()
        {:noreply, push_event(socket, "open-url", %{url: url})}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to create document: #{inspect(reason)}")}
    end
  end

  # ── Modal events ───────────────────────────────────────────────────

  def handle_event("open_modal", _params, socket) do
    {:noreply,
     assign(socket,
       modal_open: true,
       modal_step: "choose",
       modal_selected_template: nil,
       modal_variables: [],
       modal_creating: false
     )}
  end

  def handle_event("modal_close", _params, socket) do
    {:noreply, assign(socket, modal_open: false)}
  end

  def handle_event("modal_back", _params, socket) do
    {:noreply,
     assign(socket, modal_step: "choose", modal_selected_template: nil, modal_variables: [])}
  end

  def handle_event("modal_create_blank", _params, socket) do
    case Documents.create_document() do
      {:ok, %{url: url}} ->
        broadcast_files_changed()

        {:noreply,
         socket
         |> assign(modal_open: false)
         |> push_event("open-url", %{url: url})}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("modal_select_template", %{"id" => file_id, "name" => name}, socket) do
    # Detect variables from the template
    variables =
      case Documents.detect_variables(file_id) do
        {:ok, vars} ->
          PhoenixKitDocumentCreator.Variable.build_definitions(vars)
          |> Enum.map(&Map.from_struct/1)

        _ ->
          []
      end

    template = %{"id" => file_id, "name" => name}

    if variables == [] do
      # No variables — create directly
      case Documents.create_document_from_template(file_id, %{}, name: name) do
        {:ok, %{url: url}} ->
          broadcast_files_changed()
          {:noreply, socket |> assign(modal_open: false) |> push_event("open-url", %{url: url})}

        {:error, reason} ->
          {:noreply, assign(socket, error: "Failed: #{inspect(reason)}")}
      end
    else
      {:noreply,
       assign(socket,
         modal_step: "variables",
         modal_selected_template: template,
         modal_variables: variables
       )}
    end
  end

  def handle_event("modal_create_from_template", params, socket) do
    template = socket.assigns.modal_selected_template
    file_id = template["id"]
    doc_name = Map.get(params, "doc_name", template["name"])
    variable_values = Map.get(params, "var", %{})

    socket = assign(socket, modal_creating: true)

    case Documents.create_document_from_template(file_id, variable_values, name: doc_name) do
      {:ok, %{url: url}} ->
        broadcast_files_changed()

        {:noreply,
         socket
         |> assign(modal_open: false, modal_creating: false)
         |> push_event("open-url", %{url: url})}

      {:error, reason} ->
        {:noreply, assign(socket, modal_creating: false, error: "Failed: #{inspect(reason)}")}
    end
  end

  # ── PDF export ───────────────────────────────────────────────────

  def handle_event("export_pdf", %{"id" => file_id, "name" => name}, socket) do
    case Documents.export_pdf(file_id) do
      {:ok, pdf_binary} when byte_size(pdf_binary) <= @max_pdf_push_bytes ->
        base64 = Base.encode64(pdf_binary)
        filename = sanitize_filename(name)
        {:noreply, push_event(socket, "download-pdf", %{base64: base64, filename: filename})}

      {:ok, _large_pdf} ->
        {:noreply,
         assign(socket,
           error: "PDF is too large to download directly. Please export from Google Docs instead."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: "PDF export failed: #{inspect(reason)}")}
    end
  end

  # ── Delete (soft) ────────────────────────────────────────────────

  def handle_event("delete", %{"id" => file_id}, socket) do
    result =
      if socket.assigns.live_action == :templates,
        do: Documents.delete_template(file_id),
        else: Documents.delete_document(file_id)

    case result do
      :ok ->
        broadcast_files_changed()

        socket =
          if socket.assigns.live_action == :templates do
            assign(socket,
              templates: Enum.reject(socket.assigns.templates, &(&1["id"] == file_id))
            )
          else
            assign(socket,
              documents: Enum.reject(socket.assigns.documents, &(&1["id"] == file_id))
            )
          end

        {:noreply, put_flash(socket, :info, "Moved to deleted folder")}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Delete failed: #{inspect(reason)}")}
    end
  end

  # ── Refresh ──────────────────────────────────────────────────────

  def handle_event("refresh", _params, socket) do
    send(self(), :sync_from_drive)
    {:noreply, assign(socket, loading: true)}
  end

  def handle_event("silent_refresh", _params, socket) do
    if not socket.assigns.loading and not within_cooldown?(socket) do
      send(self(), :sync_from_drive)
    end

    {:noreply, socket}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, error: nil)}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <%!-- Not connected banner --%>
      <%= if not @google_connected do %>
        <div class="card bg-base-100 shadow-sm border border-warning/30">
          <div class="card-body items-center text-center py-12">
            <span class="hero-exclamation-triangle w-12 h-12 text-warning" />
            <h2 class="card-title mt-2">Google Account Not Connected</h2>
            <p class="text-sm text-base-content/60 max-w-md">
              The Document Creator uses Google Docs for editing and Google Drive for storage.
              Connect a Google account in Settings to get started.
            </p>
            <div class="card-actions mt-4">
              <a href={settings_path()} class="btn btn-primary btn-sm">
                <span class="hero-cog-6-tooth w-4 h-4" /> Go to Settings
              </a>
            </div>
          </div>
        </div>
      <% else %>
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">
            {if @live_action == :templates, do: "Templates", else: "Documents"}
          </h1>
          <div class="flex gap-2">
            <button class="btn btn-ghost btn-sm" phx-click="refresh" disabled={@loading}>
              <span :if={@loading} class="loading loading-spinner loading-xs" />
              <span :if={not @loading} class="hero-arrow-path w-4 h-4" />
            </button>
            <%= if @live_action == :templates do %>
              <a :if={templates_folder_url()} href={templates_folder_url()} target="_blank" class="btn btn-ghost btn-sm">
                <span class="hero-folder-open w-4 h-4" /> Open Folder
              </a>
              <button class="btn btn-primary btn-sm" phx-click="new_template">
                <span class="hero-plus w-4 h-4" /> New Template
              </button>
            <% else %>
              <a :if={documents_folder_url()} href={documents_folder_url()} target="_blank" class="btn btn-ghost btn-sm">
                <span class="hero-folder-open w-4 h-4" /> Open Folder
              </a>
              <button class="btn btn-primary btn-sm" phx-click="open_modal">
                <span class="hero-document-plus w-4 h-4" /> New Document
              </button>
            <% end %>
          </div>
        </div>

        <%!-- View Toggle --%>
        <div class="flex items-center justify-end">
          <div class="flex gap-1">
            <button
              class={"btn btn-ghost btn-sm btn-square #{if @view_mode == "cards", do: "btn-active"}"}
              phx-click="switch_view"
              phx-value-mode="cards"
            >
              <span class="hero-squares-2x2 w-4 h-4" />
            </button>
            <button
              class={"btn btn-ghost btn-sm btn-square #{if @view_mode == "list", do: "btn-active"}"}
              phx-click="switch_view"
              phx-value-mode="list"
            >
              <span class="hero-list-bullet w-4 h-4" />
            </button>
          </div>
        </div>

        <%!-- Error --%>
        <div :if={@error} class="alert alert-error" phx-click="dismiss_error">
          <span class="hero-x-circle w-5 h-5" />
          <span>{@error}</span>
        </div>

        <%!-- Loading skeletons --%>
        <%= if @loading do %>
          <%= if @view_mode == "cards" do %>
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-4">
              <div
                :for={_ <- 1..5}
                class="flex flex-col animate-pulse skeleton"
                style="border: 1.5px solid oklch(var(--color-base-content) / 0.1); border-radius: 8px; overflow: hidden; padding-bottom: 12px;"
              >
                <div style="padding:16px 16px 24px 16px;display:flex;justify-content:center;">
                  <div class="skeleton" style="width:183px;height:258px;border-radius:4px;" />
                </div>
                <div class="p-3 flex-1 flex flex-col gap-2">
                  <div class="skeleton h-4 rounded w-3/4" />
                  <div class="skeleton h-3 rounded w-1/2 mt-auto" />
                </div>
                <div class="flex gap-1 px-2 pb-2 pt-1">
                  <div class="skeleton flex-1 h-6 rounded" />
                  <div class="skeleton flex-1 h-6 rounded" />
                </div>
              </div>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Modified</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={_ <- 1..6}>
                    <td><div class="skeleton h-4 rounded w-48" /></td>
                    <td><div class="skeleton h-4 rounded w-24" /></td>
                    <td class="text-right">
                      <div class="flex gap-1 justify-end">
                        <div class="skeleton h-6 w-6 rounded" />
                        <div class="skeleton h-6 w-6 rounded" />
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        <% end %>

        <%!-- Content --%>
        <%= if not @loading do %>
          <%= if @live_action == :templates do %>
            {render_file_grid(assign_files(assigns, @templates))}
          <% else %>
            {render_file_grid(assign_files(assigns, @documents))}
          <% end %>
        <% end %>
      <% end %>
    </div>

    <button id="silent-refresh-btn" phx-click="silent_refresh" class="hidden" />

    <%!-- Create document modal --%>
    <.modal
      open={@modal_open}
      templates={@templates}
      step={@modal_step}
      selected_template={@modal_selected_template}
      variables={@modal_variables}
      creating={@modal_creating}
      thumbnails={@thumbnails}
    />

    <script>
      // Idempotent script — guarded to prevent duplicate listeners on re-render (M3)
      if (!window.__pkDocCreatorInitialized) {
        window.__pkDocCreatorInitialized = true;

        window.addEventListener("phx:open-url", function(e) {
          var a = document.createElement("a");
          a.href = e.detail.url;
          a.target = "_blank";
          a.rel = "noopener";
          document.body.appendChild(a);
          a.click();
          a.remove();
        });
        window.addEventListener("phx:download-pdf", function(e) {
          var a = document.createElement("a");
          a.href = "data:application/pdf;base64," + e.detail.base64;
          a.download = e.detail.filename;
          a.click();
        });
        // Silently check for changes when tab regains focus (user returns from Google Docs)
        (function() {
          var lastHidden = 0;
          document.addEventListener("visibilitychange", function() {
            if (document.visibilityState === "hidden") {
              lastHidden = Date.now();
            } else if (document.visibilityState === "visible" && Date.now() - lastHidden > 3000) {
              var btn = document.getElementById("silent-refresh-btn");
              if (btn) btn.click();
            }
          });
        })();
      }
    </script>
    """
  end

  # ── File grid ──────────────────────────────────────────────────

  defp assign_files(assigns, files) do
    %{files: files, view_mode: assigns.view_mode, thumbnails: assigns.thumbnails}
  end

  defp render_file_grid(assigns) do
    ~H"""
    <div :if={@files == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-12">
        <span class="hero-document-text w-12 h-12 text-base-content/20" />
        <p class="text-sm text-base-content/50 mt-2">No files yet</p>
      </div>
    </div>

    <%= if @view_mode == "cards" do %>
      <div :if={@files != []} class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-4">
        <div
          :for={file <- @files}
          class="group flex flex-col card bg-base-100"
          style="border: 1.5px solid currentColor; border-radius: 8px; overflow: hidden; padding-bottom: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.3);"
        >
          <%!-- Preview --%>
          <a href={GoogleDocsClient.get_edit_url(file["id"])} target="_blank" style="display:flex;justify-content:center;padding:16px 16px 24px 16px;background:oklch(var(--color-base-200));">
            {render_thumbnail(%{thumbnail: @thumbnails[file["id"]]})}
          </a>

          <%!-- Info --%>
          <div class="p-3 flex-1 flex flex-col">
            <div class="flex items-center gap-1.5">
              <a href={GoogleDocsClient.get_edit_url(file["id"])} target="_blank" class="font-medium text-sm truncate link link-hover">
                {file["name"]}
              </a>
              <span :if={file["status"] == "lost"} class="badge badge-warning badge-xs" title="File not found in Google Drive">lost</span>
            </div>
            <p :if={file["modifiedTime"]} class="text-xs text-base-content/40 mt-auto pt-2">
              {format_time(file["modifiedTime"])}
            </p>
          </div>

          <%!-- Actions --%>
          <div class="flex gap-1 px-2 pb-2 pt-1">
            <a
              href={GoogleDocsClient.get_edit_url(file["id"])}
              target="_blank"
              class="flex-1 btn btn-ghost btn-xs py-2"
            >
              <span class="hero-pencil-square w-3 h-3" /> Edit
            </a>
            <button
              class="flex-1 btn btn-ghost btn-xs py-2"
              phx-click="export_pdf"
              phx-value-id={file["id"]}
              phx-value-name={file["name"]}
            >
              <span class="hero-arrow-down-tray w-3 h-3" /> PDF
            </button>
            <button
              class="btn btn-ghost btn-xs py-2 text-error"
              phx-click="delete"
              phx-value-id={file["id"]}
              data-confirm={"Delete \"#{file["name"]}\"? It will be moved to the deleted folder."}
            >
              <span class="hero-trash w-3 h-3" />
            </button>
          </div>
        </div>
      </div>
    <% else %>
      <div :if={@files != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Name</th>
              <th>Status</th>
              <th>Modified</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={file <- @files} class="hover:bg-base-200/50">
              <td>
                <a href={GoogleDocsClient.get_edit_url(file["id"])} target="_blank" class="font-medium link link-hover">
                  {file["name"]}
                </a>
              </td>
              <td>
                <span :if={file["status"] == "lost"} class="badge badge-warning badge-xs">lost</span>
              </td>
              <td class="text-base-content/60 text-nowrap">{format_time(file["modifiedTime"])}</td>
              <td class="text-right">
                <div class="flex gap-1 justify-end">
                  <a href={GoogleDocsClient.get_edit_url(file["id"])} target="_blank" class="btn btn-ghost btn-xs" title="Edit">
                    <span class="hero-pencil-square w-3.5 h-3.5" />
                  </a>
                  <button class="btn btn-ghost btn-xs" phx-click="export_pdf" phx-value-id={file["id"]} phx-value-name={file["name"]} title="Export PDF">
                    <span class="hero-arrow-down-tray w-3.5 h-3.5" />
                  </button>
                  <button
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="delete"
                    phx-value-id={file["id"]}
                    data-confirm={"Delete \"#{file["name"]}\"? It will be moved to the deleted folder."}
                    title="Delete"
                  >
                    <span class="hero-trash w-3.5 h-3.5" />
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  defp render_thumbnail(assigns) do
    ~H"""
    <div style="width:183px;height:258px;overflow:hidden;border-radius:4px;background:#fff;border:1px solid oklch(var(--color-base-content) / 0.2);box-shadow:0 2px 8px rgba(0,0,0,0.08);">
      <%= if @thumbnail do %>
        <img src={@thumbnail} style="width:100%;height:100%;object-fit:cover;object-position:top;" />
      <% else %>
        <div style="width:100%;height:100%;background:#fff;display:flex;align-items:center;justify-content:center;">
          <span class="loading loading-spinner loading-md text-base-300" />
        </div>
      <% end %>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp settings_path, do: PhoenixKitDocumentCreator.Paths.settings()
  defp templates_folder_url, do: Documents.templates_folder_url()
  defp documents_folder_url, do: Documents.documents_folder_url()

  defp format_time(nil), do: ""

  defp format_time(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%b %d, %Y")
      _ -> iso_string
    end
  end

  defp sanitize_filename(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> Kernel.<>(".pdf")
  end

  defp broadcast_files_changed do
    PhoenixKit.PubSubHelper.broadcast(@pubsub_topic, {:files_changed, self()})
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp within_cooldown?(socket) do
    case socket.assigns.last_loaded_at do
      nil -> false
      last -> now_ms() - last < @refresh_cooldown_ms
    end
  end
end
