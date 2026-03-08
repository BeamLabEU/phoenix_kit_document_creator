defmodule PhoenixKitDocumentCreator.Web.Components.EditorScripts do
  @moduledoc """
  JavaScript component for GrapesJS editor hooks.

  ## Architecture

  The JS source lives in `editor_hooks.js` alongside this module. It is read
  and base64-encoded at **compile time**, then emitted as a `data-` attribute
  on a hidden `<div>`. A tiny inline bootstrapper decodes it with `atob()`
  and executes it via `document.createElement("script")`.

  This module is fully self-contained — no external files need to be copied
  to the host app, no endpoint configuration or asset pipeline changes are
  required. The base64 string is baked into the compiled `.beam` file.

  ## Why not inline `<script>` tags?

  Large inline `<script>` tags inside LiveView renders do **not** work
  reliably. We discovered the following issues:

  1. **LiveView morphdom breaks `</script>` boundaries** — During the
     connected render, LiveView's DOM patching can corrupt the boundary
     between `</script>` and subsequent HTML, causing the JavaScript
     content to bleed into other elements or be rendered as visible HTML.

  2. **HTML strings inside JS confuse the rendering pipeline** — JavaScript
     code containing HTML-like strings (e.g. `'<h1>Heading</h1>'`) can be
     interpreted as actual HTML elements when the script boundary breaks.

  3. **Browser extensions (SES/Hardened JS from MetaMask etc.)** can block
     `eval()` and `new Function()` calls from inline page scripts, but
     do not block `document.createElement("script")`.

  Base64 encoding solves all three: the encoded string contains no HTML-
  significant characters (`<`, `>`, `</script>`, etc.), so nothing gets
  misinterpreted by the HTML parser or LiveView's diff engine.

  ## Editing the JavaScript

  The JS source is in `editor_hooks.js` in the same directory as this file.
  After editing it, you must recompile **from the parent app** for changes
  to take effect in the running server:

      # From the parent app directory:
      mix deps.compile phoenix_kit_document_creator --force

  Then **restart the Phoenix server** — `mix deps.compile` updates the beam
  files on disk but the running BEAM VM won't pick them up via code
  reloading (Phoenix dev reloader only watches the app's own modules, not
  dependency modules).

  The `@external_resource` annotation ensures `mix` tracks the file for
  recompilation. A content hash (`@js_version`) is embedded in the HTML
  so the bootstrapper re-executes the script on LiveView navigations when
  the JS has changed, without needing a full browser refresh.
  """
  use Phoenix.Component

  @external_resource Path.join(__DIR__, "editor_hooks.js")
  @js_source __DIR__ |> Path.join("editor_hooks.js") |> File.read!()
  @js_base64 Base.encode64(@js_source)
  @js_version to_string(:erlang.phash2(@js_source))

  @doc """
  Renders a script loader for the GrapesJS editor hooks.

  Include this at the top of any LiveView template that uses GrapesJS editors.

  ## Example

      <.editor_scripts />
      <div id="template-editor" phx-hook="GrapesJSTemplateEditor" phx-update="ignore">
        ...
      </div>
  """
  def editor_scripts(assigns) do
    assigns =
      assigns
      |> assign(:js_base64, @js_base64)
      |> assign(:js_version, @js_version)

    ~H"""
    <div id="dc-js-payload" hidden data-c={@js_base64} data-v={@js_version}></div>
    <script>
    (function(){
      var p=document.getElementById("dc-js-payload");
      if(!p) return;
      var v=p.dataset.v;
      if(window.__DocumentCreatorVersion===v) return;
      var old=document.getElementById("dc-js-script");
      if(old) old.remove();
      window.__DocumentCreatorInitialized=false;
      window.__DocumentCreatorVersion=v;
      var s=document.createElement("script");
      s.id="dc-js-script";
      s.textContent=atob(p.dataset.c);
      document.head.appendChild(s);
    })();
    </script>
    """
  end
end
