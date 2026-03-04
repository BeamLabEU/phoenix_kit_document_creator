defmodule PhoenixKitDocumentCreator.Web.Components.EditorScripts do
  @moduledoc """
  Inline JavaScript component for GrapesJS editor hooks.

  Renders all Document Creator hooks as an inline `<script>` tag.
  This follows the same pattern as PhoenixKit's markdown editor —
  JavaScript is embedded directly in the template, no external import needed.

  ## How it works

  On a full page load, inline `<script>` tags in `<body>` execute during
  HTML parsing, BEFORE deferred scripts in `<head>` (like `app.js`).
  This means the hooks are registered on `window.PhoenixKitHooks` before
  `app.js` creates the LiveSocket with `{ ...window.PhoenixKitHooks }`.

  Editor pages are entered via full page loads (`redirect/2` / plain `<a href>`)
  to ensure the inline script executes.
  """
  use Phoenix.Component

  @doc """
  Renders the GrapesJS editor hooks as an inline script.

  Include this at the top of any LiveView template that uses GrapesJS editors.

  ## Example

      <.editor_scripts />
      <div id="template-editor" phx-hook="GrapesJSTemplateEditor" phx-update="ignore">
        ...
      </div>
  """
  def editor_scripts(assigns) do
    ~H"""
    <script>
    (function() {
      "use strict";

      if (window.__DocumentCreatorInitialized) return;
      window.__DocumentCreatorInitialized = true;

      window.PhoenixKitHooks = window.PhoenixKitHooks || {};

      // ======================================================================
      // Dynamic GrapesJS loader (CDN)
      // ======================================================================

      var _gjsLoading = false;
      var _gjsLoaded = false;
      var _gjsCallbacks = [];

      function ensureGrapesJS(callback) {
        if (typeof grapesjs !== "undefined") {
          _gjsLoaded = true;
          callback();
          return;
        }
        _gjsCallbacks.push(callback);
        if (_gjsLoading) return;
        _gjsLoading = true;

        var cssUrl = "https://cdn.jsdelivr.net/npm/grapesjs@0.22.4/dist/css/grapes.min.css";
        var jsUrl = "https://cdn.jsdelivr.net/npm/grapesjs@0.22.4/dist/grapes.min.js";

        function loadScript() {
          var script = document.createElement("script");
          script.src = jsUrl;
          script.onload = function() {
            _gjsLoaded = true;
            _gjsLoading = false;
            var cbs = _gjsCallbacks.slice();
            _gjsCallbacks = [];
            cbs.forEach(function(cb) { cb(); });
          };
          script.onerror = function() {
            _gjsLoading = false;
            console.error("[DocumentCreator] Failed to load GrapesJS from " + jsUrl);
          };
          document.head.appendChild(script);
        }

        if (!document.querySelector('link[data-document-creator-grapesjs-css]')) {
          var link = document.createElement("link");
          link.rel = "stylesheet";
          link.href = cssUrl;
          link.setAttribute("data-document-creator-grapesjs-css", "true");
          link.onload = loadScript;
          link.onerror = loadScript; // still try JS even if CSS fails
          document.head.appendChild(link);
        } else {
          loadScript();
        }
      }

      // ======================================================================
      // Paper sizes (at 96 DPI)
      // ======================================================================

      var PAPER_SIZES = {
        a4:     { width: 794, height: 1123 },  // 210mm × 297mm
        letter: { width: 816, height: 1056 }   // 8.5in × 11in
      };

      function applyPaperSize(editor, size) {
        var dims = PAPER_SIZES[size] || PAPER_SIZES.a4;
        // Set width on the frame-wrapper (outside the iframe) to avoid
        // offsetting the body inside the iframe which breaks GrapesJS
        // coordinate calculations for drag/resize.
        var frame = editor.Canvas.getFrameEl();
        if (frame && frame.parentElement) {
          frame.parentElement.style.width = dims.width + 'px';
          frame.parentElement.style.margin = '0 auto';
        }
        // Set min-height on wrapper so content area has proper page height
        var wrapper = editor.DomComponents.getWrapper();
        if (wrapper) {
          wrapper.addStyle({ 'min-height': dims.height + 'px' });
        }
      }

      function setupPaperSizeListener(editor, selectId) {
        var select = document.getElementById(selectId);
        if (!select) return;
        select.addEventListener('change', function() {
          applyPaperSize(editor, select.value);
        });
      }

      // ======================================================================
      // Document-style canvas styles
      // ======================================================================

      var CANVAS_STYLES = [
        'body { font-family: Inter, -apple-system, sans-serif; font-size: 14px; line-height: 1.7; color: #1a1a1a; margin: 0; padding: 0; }',
        'h1 { font-size: 28px; font-weight: 700; margin: 0 0 12px 0; line-height: 1.3; }',
        'h2 { font-size: 20px; font-weight: 600; margin: 24px 0 8px 0; line-height: 1.3; }',
        'h3 { font-size: 16px; font-weight: 600; margin: 20px 0 6px 0; }',
        'p { margin: 0 0 12px 0; }',
        'ul, ol { margin: 0 0 12px 0; padding-left: 24px; }',
        'li { margin-bottom: 4px; }',
        'table { width: 100%; border-collapse: collapse; margin: 16px 0; }',
        'th { background: #f8f9fa; text-align: left; padding: 10px 14px; font-size: 13px; font-weight: 600; border-bottom: 2px solid #e0e0e0; }',
        'td { padding: 10px 14px; border-bottom: 1px solid #eee; font-size: 13px; }',
        'blockquote { border-left: 4px solid #d0d0d0; margin: 16px 0; padding: 8px 16px; color: #555; font-style: italic; }',
        'hr { border: none; border-top: 2px solid #e0e0e0; margin: 24px 0; }',
        'img { max-width: 100%; height: auto; border-radius: 4px; }',
        'a { color: #2563eb; text-decoration: underline; }',
        '[data-gjs-type].gjs-selected { outline: 2px solid #6366f1 !important; outline-offset: 2px; border-radius: 2px; }',
        '[data-gjs-type]:hover { outline: 1px dashed #c7c7c7 !important; outline-offset: 1px; }'
      ].join('\n');

      // ======================================================================
      // Document-mode blocks
      // ======================================================================

      function addDocumentBlocks(editor, opts) {
        var bm = editor.BlockManager;
        // Use plain HTML strings (not { type: 'text' }) — matches working original
        bm.add('heading-1', { label: 'Heading 1', category: 'Text', content: '<h1>Heading</h1>' });
        bm.add('heading-2', { label: 'Heading 2', category: 'Text', content: '<h2>Subheading</h2>' });
        bm.add('heading-3', { label: 'Heading 3', category: 'Text', content: '<h3>Section heading</h3>' });
        bm.add('paragraph', { label: 'Paragraph', category: 'Text', content: '<p>Type your text here. Click to edit.</p>' });
        bm.add('blockquote', { label: 'Quote', category: 'Text', content: '<blockquote>Quote text goes here.</blockquote>' });
        bm.add('list-ul', { label: 'Bullet List', category: 'Text', content: '<ul><li>First item</li><li>Second item</li><li>Third item</li></ul>' });
        bm.add('list-ol', { label: 'Numbered List', category: 'Text', content: '<ol><li>First item</li><li>Second item</li><li>Third item</li></ol>' });
        bm.add('divider', { label: 'Divider', category: 'Layout', content: '<hr />' });
        bm.add('two-columns', { label: '2 Columns', category: 'Layout', content: '<div style="display:flex;gap:24px;margin:16px 0;"><div style="flex:1;"><p>Left column</p></div><div style="flex:1;"><p>Right column</p></div></div>' });
        bm.add('three-columns', { label: '3 Columns', category: 'Layout', content: '<div style="display:flex;gap:24px;margin:16px 0;"><div style="flex:1;"><p>Column 1</p></div><div style="flex:1;"><p>Column 2</p></div><div style="flex:1;"><p>Column 3</p></div></div>' });
        bm.add('text-placeholder', { label: 'Text Placeholder', category: 'Elements', content: '<p style="color:#6b7280;font-style:italic;">{{ variable_name }}</p>' });
        bm.add('image', { label: 'Image', category: 'Media', content: { type: 'image', style: { 'max-width': '100%' } } });
        bm.add('table-simple', { label: 'Table', category: 'Media', content: '<table><thead><tr><th>Header 1</th><th>Header 2</th><th>Header 3</th></tr></thead><tbody><tr><td>Cell 1</td><td>Cell 2</td><td>Cell 3</td></tr><tr><td>Cell 4</td><td>Cell 5</td><td>Cell 6</td></tr></tbody></table>' });
        if (opts && opts.templateVariables) {
          bm.add('template-variable', { label: 'Variable {{ }}', category: 'Template', content: '<p style="color:#6b7280;background:#f3f4f6;padding:2px 6px;border-radius:4px;font-family:monospace;font-size:13px;display:inline-block;">{{ variable_name }}</p>' });
        }
      }

      function injectCanvasStyles(editor, opts) {
        editor.on('load', function() {
          var frame = editor.Canvas.getFrameEl();
          if (frame && frame.contentDocument) {
            var style = frame.contentDocument.createElement('style');
            style.textContent = CANVAS_STYLES;
            frame.contentDocument.head.appendChild(style);
          }

          // Wire up paper size selector if present
          if (opts && opts.paperSizeSelectId) {
            var sel = document.getElementById(opts.paperSizeSelectId);
            var paperSize = sel ? sel.value : 'a4';
            setupPaperSizeListener(editor, opts.paperSizeSelectId);
            applyPaperSize(editor, paperSize);
          }
        });
      }

      // ======================================================================
      // Theme integration — sync with PhoenixKit admin theme
      // ======================================================================

      function getDaisyColor(name) {
        return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
      }

      function applyGjsTheme(wrapperEl) {
        // Read DaisyUI theme colors and map to GrapesJS CSS variables.
        // DaisyUI stores full oklch() values, which work as CSS color values.
        var base100 = getDaisyColor('--color-base-100');
        var base200 = getDaisyColor('--color-base-200');
        var base300 = getDaisyColor('--color-base-300');
        var baseContent = getDaisyColor('--color-base-content');
        var primary = getDaisyColor('--color-primary');
        var primaryContent = getDaisyColor('--color-primary-content');
        var isDark = getComputedStyle(document.documentElement).getPropertyValue('color-scheme').trim() === 'dark';

        // Map DaisyUI colors → GrapesJS variables
        var map = {
          '--gjs-primary-color': base200 ? 'oklch(' + base200 + ')' : (isDark ? '#444' : '#f4f4f4'),
          '--gjs-secondary-color': baseContent ? 'oklch(' + baseContent + ')' : (isDark ? '#ddd' : '#333'),
          '--gjs-tertiary-color': primary ? 'oklch(' + primary + ')' : '#6366f1',
          '--gjs-quaternary-color': primary ? 'oklch(' + primary + ')' : '#6366f1',
          '--gjs-font-color': baseContent ? 'oklch(' + baseContent + ')' : (isDark ? '#ddd' : '#333'),
          '--gjs-font-color-active': baseContent ? 'oklch(' + baseContent + ')' : (isDark ? '#f8f8f8' : '#111'),
          '--gjs-main-dark-color': isDark ? 'rgba(0,0,0,0.2)' : 'rgba(0,0,0,0.08)',
          '--gjs-secondary-dark-color': isDark ? 'rgba(0,0,0,0.1)' : 'rgba(0,0,0,0.05)',
          '--gjs-main-light-color': isDark ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.05)',
          '--gjs-secondary-light-color': isDark ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.6)',
          '--gjs-soft-light-color': isDark ? 'rgba(255,255,255,0.015)' : 'rgba(0,0,0,0.02)',
          '--gjs-light-border': base300 ? 'oklch(' + base300 + ' / 0.5)' : (isDark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.1)'),
          '--gjs-arrow-color': baseContent ? 'oklch(' + baseContent + ' / 0.6)' : (isDark ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.5)'),
          '--gjs-dark-text-shadow': isDark ? 'rgba(0,0,0,0.2)' : 'rgba(0,0,0,0.05)'
        };

        Object.keys(map).forEach(function(k) {
          wrapperEl.style.setProperty(k, map[k]);
        });
      }

      function setupTheme(wrapperEl) {
        applyGjsTheme(wrapperEl);

        // Re-apply when PhoenixKit admin theme changes
        window.addEventListener('phx:set-theme', function() {
          setTimeout(function() { applyGjsTheme(wrapperEl); }, 50);
        });
        window.addEventListener('phx:set-admin-theme', function() {
          setTimeout(function() { applyGjsTheme(wrapperEl); }, 50);
        });
      }

      // ======================================================================
      // Enable absolute drag + resize on selection
      // ======================================================================

      function setupDragAndResize(editor) {
        // Free placement mode
        editor.setDragMode('absolute');

        // GrapesJS defaults resizable to false on all component types.
        // Override the base 'default' type so every component is resizable from creation.
        // See: https://github.com/GrapesJS/grapesjs/discussions/4014
        editor.DomComponents.addType('default', {
          model: { defaults: { resizable: true } }
        });
        editor.DomComponents.addType('text', {
          model: { defaults: { resizable: true } }
        });
        editor.DomComponents.addType('image', {
          model: { defaults: { resizable: true } }
        });

        // Also set on selection as fallback (for components already in the canvas)
        editor.on('component:selected', function(component) {
          if (component.get('type') !== 'wrapper' && !component.get('resizable')) {
            component.set('resizable', true);
          }
        });

        // Constrain drag to page boundaries.
        // CSS overflow:hidden clips visually during drag;
        // component:drag:end snaps position back within bounds on release.
        // Uses addStyle to merge with (not overwrite) paper-size styles.
        editor.on('load', function() {
          var wrapper = editor.DomComponents.getWrapper();
          if (wrapper) {
            wrapper.addStyle({
              position: 'relative',
              overflow: 'hidden',
              padding: '40px 48px'
            });
          }
        });

        // Clamp a component's position and size within the wrapper
        function clampToWrapper(target) {
          if (!target || target.get('type') === 'wrapper') return;
          var el = target.getEl();
          if (!el) return;

          var wrapperEl = el.closest('[data-gjs-type="wrapper"]');
          if (!wrapperEl) return;

          var wrapperW = wrapperEl.clientWidth;
          var wrapperH = wrapperEl.clientHeight;
          var style = target.getStyle();
          var left = parseInt(style.left) || 0;
          var top = parseInt(style.top) || 0;
          var width = el.offsetWidth;
          var height = el.offsetHeight;
          var updates = {};

          // Clamp size so it doesn't exceed wrapper from its position
          var maxW = wrapperW - Math.max(left, 0);
          var maxH = wrapperH - Math.max(top, 0);
          if (width > maxW) updates.width = maxW + 'px';
          if (height > maxH) updates.height = maxH + 'px';

          // Clamp position
          var effectiveW = updates.width ? maxW : width;
          var effectiveH = updates.height ? maxH : height;
          var clampedLeft = Math.max(0, Math.min(left, wrapperW - effectiveW));
          var clampedTop = Math.max(0, Math.min(top, wrapperH - effectiveH));
          if (clampedLeft !== left) updates.left = clampedLeft + 'px';
          if (clampedTop !== top) updates.top = clampedTop + 'px';

          if (Object.keys(updates).length > 0) {
            target.addStyle(updates);
          }
        }

        editor.on('component:drag:end', function(model) {
          clampToWrapper(model && model.target ? model.target : model);
        });

        // Clamp size only (not position) after resize ends
        editor.on('component:resize', function() {
          var target = editor.getSelected();
          if (!target || target.get('type') === 'wrapper') return;
          var el = target.getEl();
          if (!el) return;

          var wrapperEl = el.closest('[data-gjs-type="wrapper"]');
          if (!wrapperEl) return;

          var style = target.getStyle();
          var left = parseInt(style.left) || 0;
          var top = parseInt(style.top) || 0;
          var maxW = wrapperEl.clientWidth - Math.max(left, 0);
          var maxH = wrapperEl.clientHeight - Math.max(top, 0);
          var updates = {};

          if (el.offsetWidth > maxW) updates.width = maxW + 'px';
          if (el.offsetHeight > maxH) updates.height = maxH + 'px';

          if (Object.keys(updates).length > 0) {
            target.addStyle(updates);
          }
        });
      }

      // ======================================================================
      // Media selector integration (PhoenixKit Storage)
      // ======================================================================

      function setupMediaSelector(editor, hook) {
        // Override GrapesJS asset manager to open PhoenixKit media selector
        editor.Commands.add('open-assets', {
          run: function(ed, sender, opts) {
            hook._pendingImageTarget = opts && opts.target ? opts.target : null;
            hook.pushEvent("open_media_selector", {});
          },
          stop: function() {}
        });

        // Handle media selection from LiveView
        hook.handleEvent("media_selected", function(payload) {
          if (!payload || !payload.url) return;
          if (hook._pendingImageTarget) {
            hook._pendingImageTarget.set('src', payload.url);
            hook._pendingImageTarget = null;
          } else {
            var selected = editor.getSelected();
            if (selected && selected.is('image')) {
              selected.set('src', payload.url);
            } else {
              editor.addComponents({
                type: 'image',
                src: payload.url,
                style: { 'max-width': '100%', position: 'absolute' }
              });
            }
          }
        });
      }

      // ======================================================================
      // PDF download helper
      // ======================================================================

      function downloadPdf(detail) {
        var bin = atob(detail.base64);
        var bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        var blob = new Blob([bytes], { type: 'application/pdf' });
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = detail.filename || 'document.pdf';
        a.style.display = 'none';
        document.body.appendChild(a);
        a.click();
        setTimeout(function() { a.remove(); URL.revokeObjectURL(url); }, 100);
      }

      // ======================================================================
      // Hook 1: GrapesJSTemplateEditor
      // ======================================================================

      window.PhoenixKitHooks.GrapesJSTemplateEditor = {
        mounted() {
          var self = this;
          self._editor = null;
          self._pendingLoad = null;

          ensureGrapesJS(function() {
            var editor = grapesjs.init({
              container: '#editor-grapesjs',
              height: '700px',
              width: 'auto',
              fromElement: false,
              components: '',
              storageManager: false,
              showDevices: false,
              styleManager: { sectors: [] },
              panels: { defaults: [
                { id: 'commands', buttons: [{}] },
                { id: 'options', buttons: [
                  { id: 'sw-visibility', command: 'sw-visibility', active: true, label: '<svg viewBox="0 0 24 24" width="18"><path fill="currentColor" d="M15 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V9l-6-6zM5 19V5h9v5h5v9H5z"/></svg>' },
                  { id: 'preview', command: 'preview', label: '<svg viewBox="0 0 24 24" width="18"><path fill="currentColor" d="M12 4.5C7 4.5 2.7 7.6 1 12c1.7 4.4 6 7.5 11 7.5s9.3-3.1 11-7.5c-1.7-4.4-6-7.5-11-7.5zM12 17c-2.8 0-5-2.2-5-5s2.2-5 5-5 5 2.2 5 5-2.2 5-5 5zm0-8c-1.7 0-3 1.3-3 3s1.3 3 3 3 3-1.3 3-3-1.3-3-3-3z"/></svg>' },
                  { id: 'fullscreen', command: 'fullscreen', label: '<svg viewBox="0 0 24 24" width="18"><path fill="currentColor" d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/></svg>' }
                ]}
              ]},
              blockManager: { appendTo: '#grapesjs-blocks-panel' },
              selectorManager: { componentFirst: true },
              canvas: {
                styles: ['https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap']
              }
            });

            injectCanvasStyles(editor, { paperSizeSelectId: 'template-paper-size' });
            addDocumentBlocks(editor, { templateVariables: true });
            setupDragAndResize(editor);
            setupMediaSelector(editor, self);
            setupTheme(document.getElementById('grapesjs-wrapper'));
            self._editor = editor;

            if (self._pendingLoad) {
              var p = self._pendingLoad;
              self._pendingLoad = null;
              if (p.type === 'project') editor.loadProjectData(p.data);
              else if (p.type === 'html') editor.setComponents(p.data);
            }
          });

          self.handleEvent("load-project", function(payload) {
            if (self._editor && payload.data) {
              self._editor.loadProjectData(payload.data);
            } else {
              self._pendingLoad = { type: 'project', data: payload.data };
            }
          });

          self.handleEvent("editor-set-content", function(payload) {
            if (self._editor) {
              self._editor.setComponents(payload.html || '');
            } else {
              self._pendingLoad = { type: 'html', data: payload.html || '' };
            }
          });

          self.handleEvent("request-save-data", function() {
            if (!self._editor) return;
            var ed = self._editor;
            self.pushEvent("save_template", {
              html: ed.getHtml(),
              css: ed.getCss(),
              native: JSON.stringify(ed.getProjectData()),
              name: document.getElementById('template-name')?.value || '',
              description: document.getElementById('template-description')?.value || '',
              status: document.getElementById('template-status')?.value || 'draft',
              header_footer_uuid: document.getElementById('template-header-footer')?.value || '',
              paper_size: document.getElementById('template-paper-size')?.value || 'a4'
            });
          });

          self.handleEvent("request-content-for-pdf", function() {
            if (!self._editor) return;
            var ed = self._editor;
            var html = ed.getHtml();
            var css = ed.getCss();
            self.pushEvent("generate_pdf_with_content", {
              html: css ? html + '<style>' + css + '</style>' : html
            });
          });

          self.handleEvent("download-pdf", function(payload) {
            downloadPdf(payload);
          });
        },

        destroyed() {
          if (this._editor) {
            try { this._editor.destroy(); } catch(_) {}
            this._editor = null;
          }
        }
      };

      // ======================================================================
      // Hook 2: GrapesJSDocumentEditor
      // ======================================================================

      window.PhoenixKitHooks.GrapesJSDocumentEditor = {
        mounted() {
          var self = this;
          self._editor = null;
          self._pendingLoad = null;

          ensureGrapesJS(function() {
            var editor = grapesjs.init({
              container: '#doc-editor-grapesjs',
              height: '700px',
              width: 'auto',
              fromElement: false,
              components: '',
              storageManager: false,
              showDevices: false,
              styleManager: { sectors: [] },
              panels: { defaults: [
                { id: 'commands', buttons: [{}] },
                { id: 'options', buttons: [
                  { id: 'sw-visibility', command: 'sw-visibility', active: true, label: '<svg viewBox="0 0 24 24" width="18"><path fill="currentColor" d="M15 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V9l-6-6zM5 19V5h9v5h5v9H5z"/></svg>' },
                  { id: 'preview', command: 'preview', label: '<svg viewBox="0 0 24 24" width="18"><path fill="currentColor" d="M12 4.5C7 4.5 2.7 7.6 1 12c1.7 4.4 6 7.5 11 7.5s9.3-3.1 11-7.5c-1.7-4.4-6-7.5-11-7.5zM12 17c-2.8 0-5-2.2-5-5s2.2-5 5-5 5 2.2 5 5-2.2 5-5 5zm0-8c-1.7 0-3 1.3-3 3s1.3 3 3 3 3-1.3 3-3-1.3-3-3-3z"/></svg>' },
                  { id: 'fullscreen', command: 'fullscreen', label: '<svg viewBox="0 0 24 24" width="18"><path fill="currentColor" d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/></svg>' }
                ]}
              ]},
              blockManager: { appendTo: '#doc-grapesjs-blocks-panel' },
              selectorManager: { componentFirst: true },
              canvas: {
                styles: ['https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap']
              }
            });

            injectCanvasStyles(editor, { paperSizeSelectId: 'doc-paper-size' });
            addDocumentBlocks(editor, { templateVariables: false });
            setupDragAndResize(editor);
            setupMediaSelector(editor, self);
            setupTheme(document.getElementById('doc-grapesjs-wrapper'));
            self._editor = editor;

            if (self._pendingLoad) {
              var p = self._pendingLoad;
              self._pendingLoad = null;
              if (p.type === 'project') editor.loadProjectData(p.data);
              else if (p.type === 'html') editor.setComponents(p.data);
            }
          });

          self.handleEvent("load-project", function(payload) {
            if (self._editor && payload.data) {
              self._editor.loadProjectData(payload.data);
            } else {
              self._pendingLoad = { type: 'project', data: payload.data };
            }
          });

          self.handleEvent("editor-set-content", function(payload) {
            if (self._editor) {
              self._editor.setComponents(payload.html || '');
            } else {
              self._pendingLoad = { type: 'html', data: payload.html || '' };
            }
          });

          self.handleEvent("request-save-data", function() {
            if (!self._editor) return;
            var ed = self._editor;
            self.pushEvent("save_document", {
              html: ed.getHtml(),
              css: ed.getCss(),
              native: JSON.stringify(ed.getProjectData()),
              name: document.getElementById('doc-name')?.value || '',
              status: document.getElementById('doc-status')?.value || ''
            });
          });

          self.handleEvent("request-content-for-pdf", function() {
            if (!self._editor) return;
            var ed = self._editor;
            var html = ed.getHtml();
            var css = ed.getCss();
            self.pushEvent("generate_pdf_with_content", {
              html: css ? html + '<style>' + css + '</style>' : html
            });
          });

          self.handleEvent("download-pdf", function(payload) {
            downloadPdf(payload);
          });
        },

        destroyed() {
          if (this._editor) {
            try { this._editor.destroy(); } catch(_) {}
            this._editor = null;
          }
        }
      };

      // ======================================================================
      // Hook 3: GrapesJSHeaderFooter
      // ======================================================================

      var HF_CANVAS_STYLES = [
        'body { font-family: Helvetica, Arial, sans-serif; font-size: 12px; line-height: 1.5; color: #1a1a1a; background: #fff; position: relative; min-height: 100%; padding: 0; margin: 0; }',
        'p { margin: 0 0 4px 0; }',
        'img { max-height: 80px; width: auto; border-radius: 2px; }',
        '[data-gjs-type].gjs-selected { outline: 2px solid #6366f1 !important; outline-offset: 1px; }',
        '[data-gjs-type]:hover { outline: 1px dashed #c7c7c7 !important; }'
      ].join('\n');

      function initMiniGrapesjs(containerId) {
        var el = document.getElementById(containerId);
        if (!el) return null;
        var blocksId = containerId + '-blocks';
        var mini = grapesjs.init({
          container: '#' + containerId,
          height: '200px',
          width: 'auto',
          fromElement: false,
          components: '',
          storageManager: false,
          dragMode: 'absolute',
          deviceManager: { devices: [] },
          panels: { defaults: [] },
          blockManager: { appendTo: '#' + blocksId },
          selectorManager: { componentFirst: true },
          styleManager: { sectors: [] }
        });

        var bm = mini.BlockManager;
        bm.add('text', {
          label: 'Text', category: '',
          content: {
            type: 'text', content: 'Edit text',
            style: { position: 'absolute', top: '10px', left: '10px', 'min-width': '80px', padding: '2px 4px' }
          }
        });
        bm.add('image', {
          label: 'Image', category: '',
          content: {
            type: 'image',
            style: { position: 'absolute', top: '10px', left: '10px', 'max-height': '80px', width: 'auto' }
          }
        });
        bm.add('two-col', {
          label: '2 Columns', category: '',
          content: '<div style="position:absolute;top:10px;left:10px;display:flex;gap:12px;width:80%;"><div style="flex:1;"><p>Left</p></div><div style="flex:1;"><p>Right</p></div></div>'
        });
        bm.add('divider', {
          label: 'Divider', category: '',
          content: '<hr style="position:absolute;top:60px;left:10px;width:80%;border:none;border-top:1px solid #ddd;margin:0;" />'
        });
        bm.add('page-number', {
          label: 'Page #', category: '',
          content: {
            type: 'text',
            content: 'Page <span class="pageNumber"></span> of <span class="totalPages"></span>',
            style: { position: 'absolute', bottom: '10px', right: '10px', 'font-size': '9px', color: '#999' }
          }
        });

        mini.on('load', function() {
          var wrapper = mini.DomComponents.getWrapper();
          wrapper.setStyle({ position: 'relative', width: '100%', height: '100%', overflow: 'hidden' });
          var editorEl = el.querySelector('.gjs-editor');
          if (editorEl) editorEl.style.background = '#fff';
          var cvCanvas = el.querySelector('.gjs-cv-canvas');
          if (cvCanvas) { cvCanvas.style.background = '#fff'; cvCanvas.style.width = '100%'; }
          var frame = mini.Canvas.getFrameEl();
          if (frame && frame.contentDocument) {
            var style = frame.contentDocument.createElement('style');
            style.textContent = HF_CANVAS_STYLES;
            frame.contentDocument.head.appendChild(style);
          }
          var panelsEl = el.querySelector('.gjs-pn-panels');
          if (panelsEl) panelsEl.style.display = 'none';
        });

        return mini;
      }

      function getEditorData(editor) {
        if (!editor) return { html: '', css: '', native: '{}' };
        return {
          html: editor.getHtml(),
          css: editor.getCss(),
          native: JSON.stringify(editor.getProjectData())
        };
      }

      window.PhoenixKitHooks.GrapesJSHeaderFooter = {
        mounted() {
          var self = this;
          self._headerEditor = null;
          self._footerEditor = null;

          self.handleEvent("init-hf-editors", function(payload) {
            ensureGrapesJS(function() {
              if (self._headerEditor) { try { self._headerEditor.destroy(); } catch(_) {} }
              if (self._footerEditor) { try { self._footerEditor.destroy(); } catch(_) {} }

              setTimeout(function() {
                self._headerEditor = initMiniGrapesjs('hf-header-editor');
                self._footerEditor = initMiniGrapesjs('hf-footer-editor');

                if (payload.header_native && self._headerEditor) {
                  setTimeout(function() { self._headerEditor.loadProjectData(payload.header_native); }, 300);
                }
                if (payload.footer_native && self._footerEditor) {
                  setTimeout(function() { self._footerEditor.loadProjectData(payload.footer_native); }, 300);
                }
              }, 100);
            });
          });

          self.handleEvent("destroy-hf-editors", function() {
            if (self._headerEditor) { try { self._headerEditor.destroy(); } catch(_) {} self._headerEditor = null; }
            if (self._footerEditor) { try { self._footerEditor.destroy(); } catch(_) {} self._footerEditor = null; }
          });

          self.handleEvent("request-hf-save-data", function() {
            var hd = getEditorData(self._headerEditor);
            var fd = getEditorData(self._footerEditor);
            self.pushEvent("save_header_footer", {
              name: document.getElementById('hf-name')?.value || '',
              header_html: hd.html,
              header_css: hd.css,
              header_native: hd.native,
              footer_html: fd.html,
              footer_css: fd.css,
              footer_native: fd.native,
              header_height: document.getElementById('hf-header-height')?.value || '25mm',
              footer_height: document.getElementById('hf-footer-height')?.value || '20mm'
            });
          });
        },

        destroyed() {
          if (this._headerEditor) { try { this._headerEditor.destroy(); } catch(_) {} this._headerEditor = null; }
          if (this._footerEditor) { try { this._footerEditor.destroy(); } catch(_) {} this._footerEditor = null; }
        }
      };

      // Also register on existing liveSocket for edge cases
      if (window.liveSocket && window.liveSocket.hooks) {
        window.liveSocket.hooks.GrapesJSTemplateEditor = window.PhoenixKitHooks.GrapesJSTemplateEditor;
        window.liveSocket.hooks.GrapesJSDocumentEditor = window.PhoenixKitHooks.GrapesJSDocumentEditor;
        window.liveSocket.hooks.GrapesJSHeaderFooter = window.PhoenixKitHooks.GrapesJSHeaderFooter;
      }
    })();
    </script>
    """
  end
end
