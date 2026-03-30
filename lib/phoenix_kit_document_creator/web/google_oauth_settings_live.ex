defmodule PhoenixKitDocumentCreator.Web.GoogleOAuthSettingsLive do
  @moduledoc """
  Settings page for connecting a Google account to the Document Creator.

  Allows admins to configure OAuth 2.0 Client ID and Secret, then authorize
  a Google account whose Drive will store all templates and documents.
  """
  use Phoenix.LiveView

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  @impl true
  def mount(_params, _session, socket) do
    creds = Settings.get_json_setting(GoogleDocsClient.settings_key(), %{})

    fc = GoogleDocsClient.get_folder_config()

    {:ok,
     assign(socket,
       page_title: "Document Creator — Google Docs",
       client_id: creds["client_id"] || "",
       client_secret: creds["client_secret"] || "",
       connected: has_token?(creds),
       connected_email: creds["connected_email"] || "",
       redirect_uri: nil,
       # Folder config: path + name for each
       templates_path: fc.templates_path,
       templates_name: fc.templates_name,
       documents_path: fc.documents_path,
       documents_name: fc.documents_name,
       deleted_path: fc.deleted_path,
       deleted_name: fc.deleted_name,
       # Folder browser modal
       browser_open: false,
       browser_field: nil,
       browser_path: [],
       browser_folders: [],
       browser_loading: false,
       saving: false,
       error: nil,
       success: nil
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    # Store the base redirect URI from the actual browser URL so that
    # the "Connect" button uses the same origin Google will redirect to.
    redirect_uri = build_redirect_uri(uri)
    socket = assign(socket, redirect_uri: redirect_uri)

    # Only process OAuth callback during live WebSocket connection.
    # During dead (static) render the internal URI may differ from the
    # external URL (e.g. http vs https behind a reverse proxy), which
    # causes redirect_uri mismatch with Google's token endpoint.
    if connected?(socket) do
      handle_oauth_callback(params, redirect_uri, socket)
    else
      {:noreply, socket}
    end
  end

  defp handle_oauth_callback(%{"code" => code}, redirect_uri, socket) do
    case GoogleDocsClient.exchange_code(code, redirect_uri) do
      {:ok, creds} ->
        email = fetch_user_email(creds["access_token"])
        if email, do: save_email(email)

        {:noreply,
         socket
         |> assign(
           connected: true,
           connected_email: email || "",
           success: "Google account connected successfully"
         )
         |> push_patch(to: settings_path())}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(error: "Token exchange failed: #{inspect(reason)}")
         |> push_patch(to: settings_path())}
    end
  end

  defp handle_oauth_callback(%{"error" => error} = params, _redirect_uri, socket) do
    error_desc = Map.get(params, "error_description", error)

    {:noreply,
     socket
     |> assign(error: "Google authorization failed: #{error_desc}")
     |> push_patch(to: settings_path())}
  end

  defp handle_oauth_callback(_params, _redirect_uri, socket) do
    {:noreply, socket}
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event(
        "save_credentials",
        %{"client_id" => client_id, "client_secret" => client_secret},
        socket
      ) do
    creds = Settings.get_json_setting(GoogleDocsClient.settings_key(), %{})

    updated =
      Map.merge(creds, %{
        "client_id" => String.trim(client_id),
        "client_secret" => String.trim(client_secret)
      })

    GoogleDocsClient.save_credentials(updated)

    {:noreply,
     assign(socket,
       client_id: updated["client_id"],
       client_secret: updated["client_secret"],
       success: "Credentials saved",
       error: nil
     )}
  end

  def handle_event("save_folders", params, socket) do
    creds = Settings.get_json_setting(GoogleDocsClient.settings_key(), %{})

    new = %{
      "folder_path_templates" => String.trim(params["templates_path"] || ""),
      "folder_name_templates" => String.trim(params["templates_name"] || ""),
      "folder_path_documents" => String.trim(params["documents_path"] || ""),
      "folder_name_documents" => String.trim(params["documents_name"] || ""),
      "folder_path_deleted" => String.trim(params["deleted_path"] || ""),
      "folder_name_deleted" => String.trim(params["deleted_name"] || "")
    }

    old_keys = Map.take(creds, Map.keys(new))
    changed = old_keys != new

    updated = Map.merge(creds, new)

    # If anything changed, clear cached folder IDs so discovery uses the new config
    updated =
      if changed do
        Map.drop(updated, [
          "templates_folder_id",
          "documents_folder_id",
          "deleted_templates_folder_id",
          "deleted_documents_folder_id"
        ])
      else
        updated
      end

    GoogleDocsClient.save_credentials(updated)

    {:noreply,
     assign(socket,
       templates_path: new["folder_path_templates"],
       templates_name: new["folder_name_templates"],
       documents_path: new["folder_path_documents"],
       documents_name: new["folder_name_documents"],
       deleted_path: new["folder_path_deleted"],
       deleted_name: new["folder_name_deleted"],
       success: "Folder settings saved",
       error: nil
     )}
  end

  def handle_event("browse_folder", %{"field" => field}, socket) do
    send(self(), {:load_drive_folders, "root"})

    {:noreply,
     assign(socket,
       browser_open: true,
       browser_field: field,
       browser_path: [%{id: "root", name: "My Drive"}],
       browser_folders: [],
       browser_loading: true
     )}
  end

  def handle_event("browser_navigate", %{"id" => folder_id, "name" => name}, socket) do
    send(self(), {:load_drive_folders, folder_id})
    path = socket.assigns.browser_path ++ [%{id: folder_id, name: name}]
    {:noreply, assign(socket, browser_path: path, browser_folders: [], browser_loading: true)}
  end

  def handle_event("browser_back", %{"index" => index}, socket) do
    index = String.to_integer(index)
    path = Enum.take(socket.assigns.browser_path, index + 1)
    %{id: folder_id} = List.last(path)
    send(self(), {:load_drive_folders, folder_id})
    {:noreply, assign(socket, browser_path: path, browser_folders: [], browser_loading: true)}
  end

  def handle_event("browser_select", _params, socket) do
    path =
      socket.assigns.browser_path
      |> Enum.drop(1)
      |> Enum.map(& &1.name)
      |> Enum.join("/")

    field = socket.assigns.browser_field
    socket = assign(socket, [{String.to_existing_atom(field), path}, browser_open: false])
    {:noreply, socket}
  end

  def handle_event("browser_close", _params, socket) do
    {:noreply, assign(socket, browser_open: false)}
  end

  def handle_event("connect", _params, socket) do
    redirect_uri = socket.assigns[:redirect_uri] || Routes.url("/admin/settings/document-creator")

    case GoogleDocsClient.authorization_url(redirect_uri) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, :client_id_not_configured} ->
        {:noreply, assign(socket, error: "Please save your Client ID and Client Secret first")}
    end
  end

  def handle_event("disconnect", _params, socket) do
    creds = Settings.get_json_setting(GoogleDocsClient.settings_key(), %{})

    # Keep client_id and client_secret, remove tokens
    cleaned =
      Map.take(creds, ["client_id", "client_secret"])

    GoogleDocsClient.save_credentials(cleaned)

    {:noreply,
     assign(socket,
       connected: false,
       connected_email: "",
       success: "Google account disconnected"
     )}
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, success: nil, error: nil)}
  end

  @impl true
  def handle_info({:load_drive_folders, folder_id}, socket) do
    folders =
      case GoogleDocsClient.list_subfolders(folder_id) do
        {:ok, folders} -> folders
        _ -> []
      end

    {:noreply, assign(socket, browser_folders: folders, browser_loading: false)}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-6 gap-6">
      <div>
        <h1 class="text-2xl font-bold">Google Docs Integration</h1>
        <p class="text-sm text-base-content/60 mt-1">
          Connect a Google account to use Google Docs for editing templates and documents.
          All content is stored in Google Drive — the connected account's Drive will contain
          <strong>templates</strong> and <strong>documents</strong> folders.
        </p>
      </div>

      <%!-- Flash messages --%>
      <div :if={@success} class="alert alert-success" phx-click="dismiss">
        <span class="hero-check-circle w-5 h-5" />
        <span>{@success}</span>
      </div>
      <div :if={@error} class="alert alert-error" phx-click="dismiss">
        <span class="hero-x-circle w-5 h-5" />
        <span>{@error}</span>
      </div>

      <%!-- OAuth Credentials --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">OAuth Credentials</h2>
          <p class="text-sm text-base-content/60">
            Create OAuth credentials in the
            <a href="https://console.cloud.google.com/apis/credentials" target="_blank" class="link">
              Google Cloud Console
            </a>
            (Application type: Web application). See setup instructions below for details.
          </p>
          <div class="text-xs text-base-content/50 bg-base-200 rounded-lg px-3 py-2 mt-1">
            <strong>Redirect URI</strong> (add this in your Google Cloud Console):
            <code class="bg-base-300 px-1 rounded ml-1">{@redirect_uri}</code>
          </div>

          <form phx-submit="save_credentials" class="space-y-4 mt-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Client ID</span></label>
              <input
                type="text"
                name="client_id"
                value={@client_id}
                class="input input-bordered w-full"
                placeholder="xxxxx.apps.googleusercontent.com"
              />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Client Secret</span></label>
              <input
                type="password"
                name="client_secret"
                value={@client_secret}
                class="input input-bordered w-full"
                placeholder="GOCSPX-..."
              />
            </div>

            <button type="submit" class="btn btn-primary btn-sm">
              Save Credentials
            </button>
          </form>
        </div>
      </div>

      <%!-- Connection Status --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">Connection Status</h2>
          <%= if @connected do %>
            <div class="flex items-center gap-3">
              <div class="badge badge-success gap-1">
                <span class="hero-check-circle w-3.5 h-3.5" /> Connected
              </div>
              <span class="text-sm text-base-content/70">{@connected_email}</span>
            </div>
            <div class="card-actions mt-4">
              <button class="btn btn-ghost btn-sm text-error" phx-click="disconnect">
                Disconnect
              </button>
            </div>
          <% else %>
            <div class="flex items-center gap-3">
              <div class="badge badge-ghost gap-1">
                <span class="hero-x-circle w-3.5 h-3.5" /> Not connected
              </div>
            </div>
            <div class="card-actions mt-4">
              <button
                :if={@client_id != "" and @client_secret != ""}
                class="btn btn-secondary btn-sm"
                phx-click="connect"
              >
                <span class="hero-link w-4 h-4" /> Connect Google Account
              </button>
              <p :if={@client_id == "" or @client_secret == ""} class="text-sm text-base-content/50">
                Save your OAuth credentials above to connect.
              </p>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Folder Names --%>
      <div :if={@connected} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">Drive Folders</h2>
          <p class="text-sm text-base-content/60">
            Customize the Google Drive folder names used for storage.
            Folders are created automatically if they don't exist.
          </p>

          <form phx-submit="save_folders" class="space-y-4 mt-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Templates</span></label>
              <div class="flex items-center gap-0">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm font-mono text-sm border border-base-300 rounded-r-none px-2 h-12 max-w-[60%] overflow-hidden"
                  phx-click="browse_folder"
                  phx-value-field="templates_path"
                  title={if @templates_path == "", do: "Browse Google Drive — root", else: "Browse Google Drive — #{@templates_path}"}
                >
                  <span class="hero-folder-open w-4 h-4 shrink-0" />
                  <span class="truncate">{if @templates_path == "", do: "/", else: "#{@templates_path}/"}</span>
                </button>
                <input
                  type="text"
                  name="templates_name"
                  value={@templates_name}
                  class="input input-bordered rounded-l-none flex-1 min-w-0 font-mono text-sm" style="min-width: 120px;"
                  placeholder="templates"
                />
                <input type="hidden" name="templates_path" value={@templates_path} />
              </div>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Documents</span></label>
              <div class="flex items-center gap-0">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm font-mono text-sm border border-base-300 rounded-r-none px-2 h-12 max-w-[60%] overflow-hidden"
                  phx-click="browse_folder"
                  phx-value-field="documents_path"
                  title={if @documents_path == "", do: "Browse Google Drive — root", else: "Browse Google Drive — #{@documents_path}"}
                >
                  <span class="hero-folder-open w-4 h-4 shrink-0" />
                  <span class="truncate">{if @documents_path == "", do: "/", else: "#{@documents_path}/"}</span>
                </button>
                <input
                  type="text"
                  name="documents_name"
                  value={@documents_name}
                  class="input input-bordered rounded-l-none flex-1 min-w-0 font-mono text-sm" style="min-width: 120px;"
                  placeholder="documents"
                />
                <input type="hidden" name="documents_path" value={@documents_path} />
              </div>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Deleted</span></label>
              <div class="flex items-center gap-0">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm font-mono text-sm border border-base-300 rounded-r-none px-2 h-12 max-w-[60%] overflow-hidden"
                  phx-click="browse_folder"
                  phx-value-field="deleted_path"
                  title={if @deleted_path == "", do: "Browse Google Drive — root", else: "Browse Google Drive — #{@deleted_path}"}
                >
                  <span class="hero-folder-open w-4 h-4 shrink-0" />
                  <span class="truncate">{if @deleted_path == "", do: "/", else: "#{@deleted_path}/"}</span>
                </button>
                <input
                  type="text"
                  name="deleted_name"
                  value={@deleted_name}
                  class="input input-bordered rounded-l-none flex-1 min-w-0 font-mono text-sm" style="min-width: 120px;"
                  placeholder="deleted"
                />
                <input type="hidden" name="deleted_path" value={@deleted_path} />
              </div>
            </div>

            <p class="text-xs text-base-content/50">
              Click the path button to browse your Google Drive. Deleted items go to
              subfolders inside the deleted folder.
              Folders are created automatically if they don't exist.
            </p>

            <button type="submit" class="btn btn-primary btn-sm">
              Save Folder Settings
            </button>
          </form>
        </div>
      </div>

      <%!-- Setup Instructions --%>
      <div class="card bg-base-200/50">
        <div class="card-body text-sm text-base-content/70 space-y-4">
          <h3 class="font-semibold text-base-content text-base">Setup Instructions</h3>

          <div>
            <h4 class="font-semibold text-base-content">1. Create a Google Cloud project</h4>
            <ol class="list-decimal list-inside space-y-1 mt-1 ml-2">
              <li>Go to the <a href="https://console.cloud.google.com" target="_blank" class="link">Google Cloud Console</a></li>
              <li>Create a new project or select an existing one</li>
            </ol>
          </div>

          <div>
            <h4 class="font-semibold text-base-content">2. Enable required APIs</h4>
            <ol class="list-decimal list-inside space-y-1 mt-1 ml-2">
              <li>Go to <a href="https://console.cloud.google.com/apis/library" target="_blank" class="link">APIs & Services → Library</a></li>
              <li>Search for <strong>Google Drive API</strong>, click it, then click <strong>Enable</strong></li>
              <li>Go back to the Library and search for <strong>Google Docs API</strong>, click it, then click <strong>Enable</strong></li>
            </ol>
            <p class="text-xs text-base-content/50 mt-1 ml-2">
              Drive API handles file listing, creation, copying, and PDF export.
              Docs API is used for reading document content and substituting template variables.
              <strong>Note:</strong> It's possible that only the Drive API is required — we're investigating
              whether the Docs API can be removed. Enable both for now to be safe.
            </p>
          </div>

          <div>
            <h4 class="font-semibold text-base-content">3. Set up OAuth consent</h4>
            <p class="text-xs text-base-content/50 mt-1 ml-2 mb-2">
              Navigate to the OAuth section using the search bar or the hamburger menu: search for <strong>"OAuth"</strong>, or go to the sidebar: <strong>APIs & Services → OAuth consent screen</strong>.
              This opens a different section with its own sidebar (Overview, Branding, Audience, Clients, Data Access, etc.).
            </p>
            <ol class="list-decimal list-inside space-y-1 mt-1 ml-2">
              <li>Go to <a href="https://console.cloud.google.com/auth/branding" target="_blank" class="link">Branding</a> in the sidebar — fill in the <strong>App name</strong> and <strong>User support email</strong>, then save</li>
              <li>Go to <a href="https://console.cloud.google.com/auth/audience" target="_blank" class="link">Audience</a> — set user type to <strong>External</strong> (or Internal for Google Workspace)</li>
              <li>Still on Audience — while the app is in <strong>Testing</strong> status, add the Google account you will connect below as a <strong>Test user</strong> (this must be the same account whose Drive will store your templates and documents)</li>
              <li><strong>(Optional)</strong> Go to <a href="https://console.cloud.google.com/auth/scopes" target="_blank" class="link">Data Access</a> — click <strong>Add or Remove Scopes</strong> and add the Drive and Docs scopes. This step may not be required — the app requests the needed scopes at connect time regardless.
              </li>
            </ol>
          </div>

          <div>
            <h4 class="font-semibold text-base-content">4. Create an OAuth Client</h4>
            <ol class="list-decimal list-inside space-y-1 mt-1 ml-2">
              <li>Go to <a href="https://console.cloud.google.com/apis/credentials" target="_blank" class="link">APIs & Services → Credentials</a></li>
              <li>Click <strong>Create Credentials → OAuth client ID</strong></li>
              <li>Application type: <strong>Web application</strong>
                <span class="text-warning text-xs block mt-0.5">(Do not select "Desktop app" — it won't support redirect URIs)</span>
              </li>
              <li>Under <strong>Authorized redirect URIs</strong>, add:
                <div class="mt-1 ml-4">
                  <code class="bg-base-300 px-2 py-1 rounded text-xs block w-fit">{@redirect_uri}</code>
                </div>
              </li>
              <li>Copy the <strong>Client ID</strong> and <strong>Client Secret</strong> into the form above</li>
            </ol>
          </div>

          <div>
            <h4 class="font-semibold text-base-content">5. Connect and authorize</h4>
            <ol class="list-decimal list-inside space-y-1 mt-1 ml-2">
              <li>Click <strong>"Save Credentials"</strong> above</li>
              <li>Click <strong>"Connect Google Account"</strong> and authorize access</li>
              <li>Google will show an "unverified app" warning — click <strong>Advanced → Go to (app name)</strong> to proceed</li>
              <li>Grant access to Google Docs and Google Drive</li>
              <li>You'll be redirected back here once connected</li>
            </ol>
          </div>

          <div>
            <h4 class="font-semibold text-base-content">6. Drive folders (automatic)</h4>
            <p class="mt-1 ml-2">
              Folders are automatically created in the connected Google Drive root the
              first time templates or documents are loaded. You can customize the folder
              names in the <strong>Drive Folders</strong> section above after connecting.
            </p>
            <p class="mt-1 ml-2">
              If folders with the configured names already exist, they will be reused.
            </p>
          </div>
        </div>
      </div>
    </div>

    <%!-- Folder browser modal --%>
    <div :if={@browser_open} class="modal modal-open">
      <div class="modal-box max-w-md">
        <h3 class="font-bold text-lg">Select Folder</h3>

        <%!-- Breadcrumb --%>
        <div class="flex items-center gap-1 mt-3 text-sm flex-wrap">
          <button
            :for={{crumb, idx} <- Enum.with_index(@browser_path)}
            class={"link link-hover #{if idx == length(@browser_path) - 1, do: "font-semibold", else: "text-base-content/60"}"}
            phx-click="browser_back"
            phx-value-index={idx}
          >
            <span :if={idx > 0} class="text-base-content/30 mr-1">/</span>
            {crumb.name}
          </button>
        </div>

        <%!-- Folder list --%>
        <div class="mt-3 border border-base-300 rounded-lg overflow-hidden" style="min-height: 200px; max-height: 400px; overflow-y: auto;">
          <div :if={@browser_loading} class="flex justify-center py-8">
            <span class="loading loading-spinner loading-md" />
          </div>
          <div :if={not @browser_loading and @browser_folders == []} class="flex justify-center py-8 text-base-content/40 text-sm">
            No subfolders
          </div>
          <ul :if={not @browser_loading and @browser_folders != []} class="menu menu-sm p-0">
            <li :for={folder <- @browser_folders}>
              <button
                class="flex items-center gap-2 rounded-none"
                phx-click="browser_navigate"
                phx-value-id={folder["id"]}
                phx-value-name={folder["name"]}
              >
                <span class="hero-folder w-4 h-4 text-base-content/50" />
                <span class="truncate">{folder["name"]}</span>
                <span class="hero-chevron-right w-3 h-3 ml-auto text-base-content/30" />
              </button>
            </li>
          </ul>
        </div>

        <%!-- Actions --%>
        <div class="modal-action">
          <button class="btn btn-ghost btn-sm" phx-click="browser_close">Cancel</button>
          <button class="btn btn-primary btn-sm" phx-click="browser_select">
            Select Current Folder
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="browser_close"></div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp has_token?(%{"access_token" => t}) when is_binary(t) and t != "", do: true
  defp has_token?(%{"refresh_token" => t}) when is_binary(t) and t != "", do: true
  defp has_token?(_), do: false

  defp settings_path do
    Routes.path("/admin/settings/document-creator")
  end

  defp build_redirect_uri(full_uri) do
    uri = URI.parse(full_uri)
    "#{uri.scheme}://#{uri.authority}#{uri.path}"
  end

  defp fetch_user_email(access_token) do
    case Req.get("https://www.googleapis.com/oauth2/v2/userinfo",
           headers: [{"authorization", "Bearer #{access_token}"}]
         ) do
      {:ok, %{status: 200, body: %{"email" => email}}} -> email
      _ -> nil
    end
  end

  defp save_email(email) do
    creds = Settings.get_json_setting(GoogleDocsClient.settings_key(), %{})
    updated = Map.put(creds, "connected_email", email)
    GoogleDocsClient.save_credentials(updated)
  end
end
