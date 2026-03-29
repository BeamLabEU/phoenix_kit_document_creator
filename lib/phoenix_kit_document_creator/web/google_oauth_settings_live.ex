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

  @settings_key "document_creator_google_oauth"

  @impl true
  def mount(_params, _session, socket) do
    creds = Settings.get_json_setting(@settings_key, %{})

    {:ok,
     assign(socket,
       page_title: "Document Creator — Google Docs",
       client_id: creds["client_id"] || "",
       client_secret: creds["client_secret"] || "",
       connected: has_token?(creds),
       connected_email: creds["connected_email"] || "",
       redirect_uri: Routes.url("/admin/settings/document-creator"),
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
    creds = Settings.get_json_setting(@settings_key, %{})

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
    creds = Settings.get_json_setting(@settings_key, %{})

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
              Two folders are automatically created in the connected Google Drive root the
              first time templates or documents are loaded:
            </p>
            <ul class="list-disc list-inside ml-6 mt-1 space-y-0.5">
              <li><strong>templates</strong> — stores template Google Docs</li>
              <li><strong>documents</strong> — stores generated documents</li>
            </ul>
            <p class="mt-1 ml-2">
              If these folders already exist, they will be reused. You can also create them
              manually before connecting if you prefer.
            </p>
          </div>
        </div>
      </div>
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
    creds = Settings.get_json_setting(@settings_key, %{})
    updated = Map.put(creds, "connected_email", email)
    GoogleDocsClient.save_credentials(updated)
  end
end
