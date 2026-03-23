// GrapesJS editor hooks for the Document Creator module.
// This file is read at compile time by editor_scripts.ex, base64-encoded,
// and embedded in the rendered HTML. After editing, run: mix compile --force
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
  // Paper sizes (CSS pixels at 96 DPI)
  //
  // Units rationale:
  //   The CSS spec defines 1in = 96px (fixed, independent of display DPI).
  //   Therefore 1mm = 96/25.4 = 3.7795px. Chrome headless (used by
  //   ChromicPDF for PDF export) uses the same 96 DPI standard, so the
  //   pixel dimensions here correspond 1:1 to the printed output.
  //
  //   Three unit systems are used across the stack:
  //     - JS (GrapesJS canvas):  CSS pixels (this file)
  //     - Elixir (ChromicPDF):   inches for paperWidth/paperHeight
  //     - CSS (@page margins):   mm strings for header_height/footer_height
  //
  //   All three resolve to the same physical dimensions through 96 DPI.
  //
  //   parseHeightToPx() converts mm → px using the 3.7795 factor.
  //   The invariant per page is: headerH + bodyH + footerH = paperHeight.
  // ======================================================================

  var PAPER_SIZES = {
    a4:      { width: 794, height: 1123 },  // 210mm × 297mm
    letter:  { width: 816, height: 1056 },  // 8.5in × 11in
    legal:   { width: 816, height: 1344 },  // 8.5in × 14in
    tabloid: { width: 1056, height: 1632 }   // 11in × 17in
  };

  function applyPaperSize(editor, size) {
    var dims = PAPER_SIZES[size] || PAPER_SIZES.a4;
    editor._paperDims = dims;
    updatePageLayout(editor);
  }

  // Update all height-related surfaces and page dividers
  function updatePageLayout(editor) {
    // If page frame exists, delegate to HF-aware layout
    var pfId = editor._pageFrameId || 'template-page-frame';
    if (document.getElementById(pfId)) {
      updateTemplateEditorLayout(editor);
      return;
    }

    var dims = editor._paperDims || PAPER_SIZES.a4;
    var pages = editor._pageCount || 1;
    var totalHeight = dims.height * pages;

    // Set width and total height on the frame-wrapper (outside the iframe)
    var frame = editor.Canvas.getFrameEl();
    if (frame && frame.parentElement) {
      frame.parentElement.style.width = dims.width + 'px';
      frame.parentElement.style.margin = '0 auto';
      frame.parentElement.style.height = totalHeight + 'px';
    }
    if (frame) {
      frame.style.height = totalHeight + 'px';
    }
    // Set min-height on wrapper
    var wrapper = editor.DomComponents.getWrapper();
    if (wrapper) {
      wrapper.addStyle({ 'min-height': totalHeight + 'px' });
    }
    // Resize the canvas container to fit
    var canvas = editor.Canvas.getElement();
    if (canvas) {
      canvas.style.height = totalHeight + 'px';
    }
    // Draw page dividers inside the iframe
    updatePageDividers(editor, dims, pages);
  }

  function updatePageDividers(editor, dims, pages) {
    var frame = editor.Canvas.getFrameEl();
    if (!frame || !frame.contentDocument) return;
    var doc = frame.contentDocument;

    // Remove existing dividers
    var old = doc.querySelectorAll('.gjs-page-divider');
    for (var i = 0; i < old.length; i++) old[i].remove();

    // Add dividers between pages
    for (var p = 1; p < pages; p++) {
      var divider = doc.createElement('div');
      divider.className = 'gjs-page-divider';
      divider.style.cssText = [
        'position: absolute',
        'left: 0',
        'width: 100%',
        'top: ' + (dims.height * p) + 'px',
        'height: 0',
        'border-top: 2px dashed #cbd5e1',
        'pointer-events: none',
        'z-index: 1',
        'box-sizing: border-box'
      ].join(';');
      // Page label
      var label = doc.createElement('span');
      label.style.cssText = [
        'position: absolute',
        'right: 8px',
        'top: 4px',
        'font-size: 10px',
        'color: #94a3b8',
        'font-family: sans-serif',
        'pointer-events: none'
      ].join(';');
      label.textContent = 'Page ' + p + ' / ' + (p + 1);
      divider.appendChild(label);
      doc.body.appendChild(divider);
    }
  }

  // Build the srcdoc string for an HF preview iframe
  function hfSrcdoc(html, css) {
    var cssTag = (css && css.trim() !== '') ? '<style>' + css + '</style>' : '';
    return '<!DOCTYPE html><html><head>' +
      '<style>body{margin:0;padding:4px 8px;font-family:Helvetica,Arial,sans-serif;font-size:12px;overflow:hidden;}</style>' +
      cssTag + '</head><body>' + html + '</body></html>';
  }

  // Stored HF content so internal page-break overlays can re-use it
  var _hfStore = { header: null, footer: null };

  // Update a header or footer preview region in the template editor
  function updateTemplateHFRegion(type, html, css, heightStr) {
    var region = document.getElementById('template-' + type + '-region');
    var iframe = document.getElementById('template-' + type + '-iframe');
    var separator = document.getElementById('template-' + type + '-separator');
    if (!region) return;

    var hasContent = html && html.trim() !== '';
    var heightPx = hasContent ? Math.round(parseHeightToPx(heightStr)) : 0;

    // Store for internal page-break overlays
    _hfStore[type] = hasContent ? { html: html, css: css, heightStr: heightStr, heightPx: heightPx } : null;

    if (hasContent) {
      region.style.display = 'block';
      region.style.height = heightPx + 'px';
      if (separator) separator.style.display = 'block';
      if (iframe) iframe.srcdoc = hfSrcdoc(html, css);
    } else {
      region.style.display = 'none';
      region.style.height = '0px';
      if (separator) separator.style.display = 'none';
      if (iframe) iframe.srcdoc = '';
    }
  }

  // Recalculate template editor layout accounting for header/footer regions.
  //
  // The canvas height is exactly bodyPerPage × pages — no extra space.
  // This matches the PDF output where Chrome breaks content every
  // bodyPerPage pixels. Page-break indicators are drawn as overlays
  // at the boundaries so they don't shift content positions.
  //
  // When header/footer sizes change, the page count is auto-adjusted
  // so that all existing content still fits within the canvas.
  function updateTemplateEditorLayout(editor) {
    if (!editor) return;
    var dims = editor._paperDims || PAPER_SIZES.a4;
    var pages = editor._pageCount || 1;

    var headerRegion = document.getElementById('template-header-region');
    var footerRegion = document.getElementById('template-footer-region');
    var headerSep = document.getElementById('template-header-separator');
    var footerSep = document.getElementById('template-footer-separator');

    var headerH = (headerRegion && headerRegion.style.display !== 'none') ? headerRegion.offsetHeight : 0;
    var footerH = (footerRegion && footerRegion.style.display !== 'none') ? footerRegion.offsetHeight : 0;

    var sepVisualH = 0;
    if (headerSep && headerSep.style.display !== 'none') sepVisualH += 2;
    if (footerSep && footerSep.style.display !== 'none') sepVisualH += 2;

    // Body height per page = paperHeight - headerH - footerH (exact)
    var bodyPerPage = dims.height - headerH - footerH;
    if (bodyPerPage < 100) bodyPerPage = dims.height;

    // Auto-adjust page count so existing content fits.
    // Temporarily clear the wrapper min-height so scrollHeight reflects
    // actual content size, not the previously forced canvas height.
    var frame = editor.Canvas.getFrameEl();
    var wrapper = editor.DomComponents.getWrapper();
    if (wrapper) wrapper.addStyle({ 'min-height': '0px' });

    var contentHeight = 0;
    if (frame && frame.contentDocument && frame.contentDocument.body) {
      // Force reflow after clearing min-height
      frame.contentDocument.body.offsetHeight;
      contentHeight = frame.contentDocument.body.scrollHeight;
    }
    if (contentHeight > bodyPerPage * pages) {
      pages = Math.ceil(contentHeight / bodyPerPage);
      editor._pageCount = pages;
    }

    // Canvas = exactly bodyPerPage × pages (matches PDF content area)
    var canvasHeight = bodyPerPage * pages;

    // Page frame = top header + separators + canvas + bottom footer
    var pageFrame = document.getElementById(editor._pageFrameId || 'template-page-frame');
    if (pageFrame) {
      pageFrame.style.height = (headerH + sepVisualH + canvasHeight + footerH) + 'px';
      pageFrame.style.width = dims.width + 'px';
      pageFrame.style.minWidth = dims.width + 'px';
    }

    // Resize GrapesJS canvas surfaces
    if (frame && frame.parentElement) {
      frame.parentElement.style.width = dims.width + 'px';
      frame.parentElement.style.margin = '0';
      frame.parentElement.style.height = canvasHeight + 'px';
    }
    if (frame) frame.style.height = canvasHeight + 'px';

    var wrapper = editor.DomComponents.getWrapper();
    if (wrapper) wrapper.addStyle({ 'min-height': canvasHeight + 'px' });

    var canvas = editor.Canvas.getElement();
    if (canvas) canvas.style.height = canvasHeight + 'px';

    // Draw page-break indicators at boundaries
    updatePageBreakIndicators(editor, pages, headerH, footerH, bodyPerPage, sepVisualH);
  }

  // Visual gap between pages in the editor
  var PAGE_GAP_H = 16;

  // Draw page-break overlays at each boundary showing repeated
  // footer (end of page) and header (start of next page).
  // These overlays sit on top of the canvas edges — they don't change
  // the canvas height, so content positions still match the PDF exactly.
  function updatePageBreakIndicators(editor, pages, headerH, footerH, bodyPerPage, sepVisualH) {
    var pageFrame = document.getElementById(editor._pageFrameId || 'template-page-frame');
    if (!pageFrame) return;

    // Remove old indicators
    var old = pageFrame.querySelectorAll('.dc-page-break-overlay');
    for (var i = 0; i < old.length; i++) old[i].remove();

    // Also remove old in-canvas dividers
    var frame = editor.Canvas.getFrameEl();
    if (frame && frame.contentDocument) {
      var oldDividers = frame.contentDocument.querySelectorAll('.gjs-page-divider');
      for (var j = 0; j < oldDividers.length; j++) oldDividers[j].remove();
    }

    if (pages <= 1) return;

    // Offset from top of page frame to start of GrapesJS canvas
    var canvasTop = headerH + (sepVisualH > 0 ? 2 : 0);

    var hasHeader = headerH > 0 && _hfStore.header;
    var hasFooter = footerH > 0 && _hfStore.footer;

    // Total overlay height at each break
    var overlayH = (hasFooter ? footerH : 0) + PAGE_GAP_H + (hasHeader ? headerH : 0);
    if (!hasHeader && !hasFooter) overlayH = PAGE_GAP_H;

    for (var p = 1; p < pages; p++) {
      // The page break point on the canvas
      var breakY = canvasTop + bodyPerPage * p;

      // Position the overlay centered on the break point:
      // footer extends above, gap + header extend below
      var aboveH = hasFooter ? footerH : 0;
      var overlayTop = breakY - aboveH;

      var overlay = document.createElement('div');
      overlay.className = 'dc-page-break-overlay';
      overlay.style.cssText = [
        'position: absolute',
        'left: 0',
        'width: 100%',
        'top: ' + overlayTop + 'px',
        'height: ' + overlayH + 'px',
        'z-index: 5',
        'pointer-events: none',
        'display: flex',
        'flex-direction: column'
      ].join(';');

      // Footer preview (end of page p)
      if (hasFooter) {
        var footerDiv = document.createElement('div');
        footerDiv.style.cssText = 'height:' + footerH + 'px;overflow:hidden;position:relative;background:#fff;border-top:1px solid #e2e8f0;';
        var footerIframe = document.createElement('iframe');
        footerIframe.style.cssText = 'width:100%;height:100%;border:none;pointer-events:none;';
        footerIframe.sandbox = '';
        footerIframe.scrolling = 'no';
        footerIframe.srcdoc = hfSrcdoc(_hfStore.footer.html, _hfStore.footer.css);
        footerDiv.appendChild(footerIframe);
        var footerTint = document.createElement('div');
        footerTint.style.cssText = 'position:absolute;inset:0;background:rgba(0,0,0,0.03);pointer-events:none;';
        footerDiv.appendChild(footerTint);
        overlay.appendChild(footerDiv);
      }

      // Page gap with label
      var gap = document.createElement('div');
      gap.style.cssText = [
        'height: ' + PAGE_GAP_H + 'px',
        'background: #e5e7eb',
        'display: flex',
        'align-items: center',
        'justify-content: center',
        'font-size: 10px',
        'color: #6b7280',
        'font-family: sans-serif',
        'user-select: none'
      ].join(';');
      gap.textContent = 'Page ' + p + '  \u2022  Page ' + (p + 1);
      overlay.appendChild(gap);

      // Header preview (start of page p+1)
      if (hasHeader) {
        var headerDiv = document.createElement('div');
        headerDiv.style.cssText = 'height:' + headerH + 'px;overflow:hidden;position:relative;background:#fff;border-bottom:1px solid #e2e8f0;';
        var headerIframe = document.createElement('iframe');
        headerIframe.style.cssText = 'width:100%;height:100%;border:none;pointer-events:none;';
        headerIframe.sandbox = '';
        headerIframe.scrolling = 'no';
        headerIframe.srcdoc = hfSrcdoc(_hfStore.header.html, _hfStore.header.css);
        headerDiv.appendChild(headerIframe);
        var headerTint = document.createElement('div');
        headerTint.style.cssText = 'position:absolute;inset:0;background:rgba(0,0,0,0.03);pointer-events:none;';
        headerDiv.appendChild(headerTint);
        overlay.appendChild(headerDiv);
      }

      pageFrame.appendChild(overlay);
    }
  }

  function addPage(editor) {
    editor._pageCount = (editor._pageCount || 1) + 1;
    updatePageLayout(editor);
  }

  function removePage(editor) {
    if ((editor._pageCount || 1) <= 1) return;

    // Check if content extends into the last page — if so, don't remove it
    var dims = editor._paperDims || PAPER_SIZES.a4;
    var headerRegion = document.getElementById('template-header-region');
    var footerRegion = document.getElementById('template-footer-region');
    var headerH = (headerRegion && headerRegion.style.display !== 'none') ? headerRegion.offsetHeight : 0;
    var footerH = (footerRegion && footerRegion.style.display !== 'none') ? footerRegion.offsetHeight : 0;
    var bodyPerPage = dims.height - headerH - footerH;
    if (bodyPerPage < 100) bodyPerPage = dims.height;

    var wrapper = editor.DomComponents.getWrapper();
    if (wrapper) wrapper.addStyle({ 'min-height': '0px' });

    var frame = editor.Canvas.getFrameEl();
    var contentHeight = 0;
    if (frame && frame.contentDocument && frame.contentDocument.body) {
      frame.contentDocument.body.offsetHeight;
      contentHeight = frame.contentDocument.body.scrollHeight;
    }

    var newPages = editor._pageCount - 1;
    if (contentHeight > bodyPerPage * newPages) {
      // Content extends into the last page — can't remove it
      // Restore min-height and return
      if (wrapper) wrapper.addStyle({ 'min-height': (bodyPerPage * editor._pageCount) + 'px' });
      return;
    }

    editor._pageCount = newPages;
    updatePageLayout(editor);
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
    bm.add('divider', { label: 'Divider', category: 'Layout', content: '<hr style="width:100%;border:none;border-top:2px solid #e0e0e0;margin:24px 0;" />' });
    bm.add('two-columns', { label: '2 Columns', category: 'Layout', content: '<div style="display:flex;gap:24px;margin:16px 0;"><div style="flex:1;"><p>Left column</p></div><div style="flex:1;"><p>Right column</p></div></div>' });
    bm.add('three-columns', { label: '3 Columns', category: 'Layout', content: '<div style="display:flex;gap:24px;margin:16px 0;"><div style="flex:1;"><p>Column 1</p></div><div style="flex:1;"><p>Column 2</p></div><div style="flex:1;"><p>Column 3</p></div></div>' });
    bm.add('text-placeholder', { label: 'Text Placeholder', category: 'Elements', content: '<p style="color:#6b7280;font-style:italic;">{{ variable_name }}</p>' });
    bm.add('image', { label: 'Image', category: 'Media', content: { type: 'image', style: { 'max-width': '100%' } } });
    bm.add('table-simple', { label: 'Table', category: 'Media', content: '<table><thead><tr><th>Header 1</th><th>Header 2</th><th>Header 3</th></tr></thead><tbody><tr><td>Cell 1</td><td>Cell 2</td><td>Cell 3</td></tr><tr><td>Cell 4</td><td>Cell 5</td><td>Cell 6</td></tr></tbody></table>' });


  }

  // Inject (or re-inject) CANVAS_STYLES into the GrapesJS iframe.
  // Called on load and after every loadProjectData/setComponents
  // since those can refresh the iframe and wipe injected styles.
  function ensureCanvasStyles(editor) {
    var frame = editor.Canvas.getFrameEl();
    if (frame && frame.contentDocument) {
      var existing = frame.contentDocument.getElementById('pkdc-canvas-styles');
      if (!existing) {
        var style = frame.contentDocument.createElement('style');
        style.id = 'pkdc-canvas-styles';
        style.textContent = CANVAS_STYLES;
        frame.contentDocument.head.appendChild(style);
      }
    }
  }

  function injectCanvasStyles(editor, opts) {
    editor.on('load', function() {
      ensureCanvasStyles(editor);

      // Wire up paper size selector if present
      if (opts && opts.paperSizeSelectId) {
        var sel = document.getElementById(opts.paperSizeSelectId);
        var paperSize = sel ? sel.value : 'a4';
        setupPaperSizeListener(editor, opts.paperSizeSelectId);
        applyPaperSize(editor, paperSize);
      }
    });

    // Re-inject after canvas iframe refreshes (loadProjectData/setComponents
    // trigger an async iframe reload that wipes injected styles)
    editor.on('canvas:frame:load', function() {
      ensureCanvasStyles(editor);
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
  // Shared editor hook factory
  // ======================================================================
  //
  // Both the template and document editors use the same GrapesJS setup.
  // Config is read from data-* attributes on the hook element:
  //   data-editor-id        — GrapesJS container element ID
  //   data-wrapper-id       — outer wrapper element ID (for theme)
  //   data-page-frame-id    — page frame element ID
  //   data-right-panel-id   — blocks right-panel element ID
  //   data-blocks-panel-id  — blocks panel element ID
  //   data-paper-size-id    — paper size select element ID (optional)
  //   data-name-id          — name input element ID
  //   data-save-event       — LiveView event name for saving
  //   data-template-vars    — "true" to show template variable blocks
  //
  // Extra save fields (description, header_uuid, footer_uuid, paper_size)
  // are included automatically if the corresponding DOM elements exist.

  function createEditorHook() {
    return {
      mounted() {
        var self = this;
        self._editor = null;
        self._pendingLoad = null;
        self._pendingHF = { header: null, footer: null };

        // Read config from data attributes
        var el = self.el;
        var editorId = el.dataset.editorId;
        var wrapperId = el.dataset.wrapperId;
        var pageFrameId = el.dataset.pageFrameId;
        var rightPanelId = el.dataset.rightPanelId;
        var blocksPanelId = el.dataset.blocksPanelId;
        var paperSizeId = el.dataset.paperSizeId || '';
        var nameId = el.dataset.nameId;
        var saveEvent = el.dataset.saveEvent;
        var templateVars = el.dataset.templateVars === 'true';

        ensureGrapesJS(function() {
          var editor = grapesjs.init({
            container: '#' + editorId,
            height: 'auto',
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
            blockManager: { appendTo: '#' + blocksPanelId },
            selectorManager: { componentFirst: true },
            canvas: {
              styles: [
                'https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap',
                'data:text/css;base64,' + btoa(CANVAS_STYLES)
              ]
            }
          });

          editor._pageCount = 1;
          editor._paperDims = PAPER_SIZES.a4;
          editor._pageFrameId = pageFrameId;
          injectCanvasStyles(editor, { paperSizeSelectId: paperSizeId });
          addDocumentBlocks(editor, { templateVariables: templateVars });
          setupDragAndResize(editor);
          setupMediaSelector(editor, self);
          setupTheme(document.getElementById(wrapperId));
          self._editor = editor;

          // Listen for add/remove page events from the LiveView button
          self.el.addEventListener('add-page', function() { addPage(editor); });
          self.el.addEventListener('remove-page', function() { removePage(editor); });

          if (self._pendingLoad) {
            var p = self._pendingLoad;
            self._pendingLoad = null;
            if (p.type === 'project') editor.loadProjectData(p.data);
            else if (p.type === 'html') editor.setComponents(p.data);
            ensureCanvasStyles(editor);
            if (p.page_count) {
              editor._pageCount = parseInt(p.page_count) || 1;
              updatePageLayout(editor);
            }
          }

          // Apply any pending HF region data that arrived before editor was ready
          if (self._pendingHF.header) {
            var h = self._pendingHF.header;
            updateTemplateHFRegion('header', h.html, h.css, h.height);
            self._pendingHF.header = null;
          }
          if (self._pendingHF.footer) {
            var f = self._pendingHF.footer;
            updateTemplateHFRegion('footer', f.html, f.css, f.height);
            self._pendingHF.footer = null;
          }

          // Move GrapesJS panels bar above the page frame so the page
          // shows header → body → footer with no toolbar in between.
          editor.on('load', function() {
            var pageFrame = document.getElementById(pageFrameId);
            var rightPanel = document.getElementById(rightPanelId);
            var panelsEl = document.querySelector('#' + editorId + ' .gjs-pn-panels')
              || document.querySelector('#' + editorId + ' .gjs-pn-panel');
            if (panelsEl && pageFrame && pageFrame.parentElement) {
              var toMove = panelsEl.classList.contains('gjs-pn-panels') ? panelsEl : panelsEl.parentElement;
              var col = document.createElement('div');
              col.style.display = 'flex';
              col.style.flexDirection = 'column';
              col.style.width = '100%';
              var row = document.createElement('div');
              row.style.display = 'flex';
              row.style.alignItems = 'flex-start';
              pageFrame.parentElement.insertBefore(col, pageFrame);
              col.appendChild(toMove);
              col.appendChild(row);
              row.appendChild(pageFrame);
              if (rightPanel) row.appendChild(rightPanel);
            }
            requestAnimationFrame(function() {
              updateTemplateEditorLayout(editor);
              updatePageLayout(editor);
            });
          });
        });

        self.handleEvent("load-project", function(payload) {
          if (self._editor && payload.data) {
            self._editor.loadProjectData(payload.data);
            ensureCanvasStyles(self._editor);
            if (payload.page_count) {
              self._editor._pageCount = parseInt(payload.page_count) || 1;
              updatePageLayout(self._editor);
            }
          } else {
            self._pendingLoad = { type: 'project', data: payload.data, page_count: payload.page_count };
          }
        });

        self.handleEvent("editor-set-content", function(payload) {
          if (self._editor) {
            self._editor.setComponents(payload.html || '');
            ensureCanvasStyles(self._editor);
            if (payload.page_count) {
              self._editor._pageCount = parseInt(payload.page_count) || 1;
              updatePageLayout(self._editor);
            }
          } else {
            self._pendingLoad = { type: 'html', data: payload.html || '', page_count: payload.page_count };
          }
        });

        self.handleEvent("request-save-data", function() {
          if (!self._editor) return;
          var ed = self._editor;
          var data = {
            html: ed.getHtml(),
            css: ed.getCss(),
            native: JSON.stringify(ed.getProjectData()),
            page_count: String(ed._pageCount || 1)
          };
          // Always include name
          var nameEl = document.getElementById(nameId);
          if (nameEl) data.name = nameEl.value || '';
          // Include optional fields if their DOM elements exist
          var descEl = document.getElementById('template-description');
          if (descEl) data.description = descEl.value || '';
          var headerEl = document.getElementById('template-header');
          if (headerEl) data.header_uuid = headerEl.value || '';
          var footerEl = document.getElementById('template-footer');
          if (footerEl) data.footer_uuid = footerEl.value || '';
          var paperEl = document.getElementById(paperSizeId);
          if (paperEl) data.paper_size = paperEl.value || 'a4';

          self.pushEvent(saveEvent, data);
        });

        self.handleEvent("request-content-for-pdf", function(payload) {
          if (!self._editor) return;
          var ed = self._editor;
          var html = ed.getHtml();
          var css = ed.getCss();
          var paperEl = document.getElementById(paperSizeId);
          self.pushEvent("generate_pdf_with_content", {
            html: css ? html + '<style>' + css + '</style>' : html,
            paper_size: paperEl ? paperEl.value : ((payload && payload.paper_size) || 'a4')
          });
        });

        self.handleEvent("download-pdf", function(payload) {
          downloadPdf(payload);
        });

        // Header/footer region updates
        self.handleEvent("update-hf-region", function(payload) {
          updateTemplateHFRegion(payload.type, payload.html, payload.css, payload.height);
          if (self._editor) {
            requestAnimationFrame(function() {
              updateTemplateEditorLayout(self._editor);
              self._editor.refresh();
            });
          } else {
            self._pendingHF[payload.type] = payload;
          }
        });
      },

      destroyed() {
        if (this._editor) {
          try { this._editor.destroy(); } catch(_) {}
          this._editor = null;
        }
      }
    };
  }

  // Both hooks use the same factory — config comes from data-* attributes
  window.PhoenixKitHooks.GrapesJSTemplateEditor = createEditorHook();
  window.PhoenixKitHooks.GrapesJSDocumentEditor = createEditorHook();

  // ======================================================================
  // Hook 3: GrapesJSHFEditor (full-page header/footer editor)
  // ======================================================================

  var HF_CANVAS_STYLES = [
    'body { font-family: Helvetica, Arial, sans-serif; font-size: 12px; line-height: 1.5; color: #1a1a1a; background: #fff; position: relative; min-height: 100%; padding: 0; margin: 0; }',
    'p { margin: 0 0 4px 0; }',
    'img { max-height: 80px; width: auto; border-radius: 2px; }',
    '[data-gjs-type].gjs-selected { outline: 2px solid #6366f1 !important; outline-offset: 1px; }',
    '[data-gjs-type]:hover { outline: 1px dashed #c7c7c7 !important; }'
  ].join('\n');

  // Convert CSS height string (e.g. "25mm", "100px") to pixels at 96 DPI
  function parseHeightToPx(heightStr) {
    if (!heightStr) return 25 * 3.7795;
    var val = parseFloat(heightStr);
    if (isNaN(val)) return 25 * 3.7795;
    if (heightStr.indexOf('px') !== -1) return val;
    // Default: treat as mm (1mm = 3.7795px at 96 DPI)
    return val * 3.7795;
  }

  // Update page frame, editor region, and body placeholder dimensions
  function updateHFLayout(paperSize, heightStr) {
    var dims = PAPER_SIZES[paperSize] || PAPER_SIZES.a4;
    var hfPx = Math.round(parseHeightToPx(heightStr));
    // Clamp: header/footer can't exceed page height
    if (hfPx > dims.height) hfPx = dims.height;
    var bodyPx = Math.max(0, dims.height - hfPx);

    var pageFrame = document.getElementById('hf-page-frame');
    if (pageFrame) {
      pageFrame.style.width = dims.width + 'px';
      pageFrame.style.height = dims.height + 'px';
    }

    var editorEl = document.getElementById('hf-editor');
    if (editorEl) {
      editorEl.style.height = hfPx + 'px';
      editorEl.style.flexShrink = '0';
      editorEl.style.flexGrow = '0';
      editorEl.style.overflow = 'hidden';
    }

    var bodyEl = document.getElementById('hf-body-placeholder');
    if (bodyEl) bodyEl.style.flex = '1 1 auto';
  }

  function initPageAwareHFEditor(opts) {
    var el = document.getElementById(opts.containerId);
    if (!el) return null;

    // Set initial dimensions
    updateHFLayout(opts.paperSize, opts.height);

    var hfPx = Math.round(parseHeightToPx(opts.height));
    var mini = grapesjs.init({
      container: '#' + opts.containerId,
      height: hfPx + 'px',
      width: 'auto',
      fromElement: false,
      components: '',
      storageManager: false,
      dragMode: 'absolute',
      deviceManager: { devices: [] },
      panels: { defaults: [] },
      blockManager: { appendTo: '#' + opts.blocksId },
      selectorManager: { componentFirst: true },
      styleManager: { sectors: [] }
    });

    var bm = mini.BlockManager;
    var abs = 'position:absolute;top:10px;left:10px;';
    bm.add('heading-1', { label: 'Heading 1', category: 'Text', content: '<h1 style="' + abs + '">Heading</h1>' });
    bm.add('heading-2', { label: 'Heading 2', category: 'Text', content: '<h2 style="' + abs + '">Subheading</h2>' });
    bm.add('heading-3', { label: 'Heading 3', category: 'Text', content: '<h3 style="' + abs + '">Section heading</h3>' });
    bm.add('paragraph', { label: 'Paragraph', category: 'Text', content: '<p style="' + abs + '">Type your text here. Click to edit.</p>' });
    bm.add('blockquote', { label: 'Quote', category: 'Text', content: '<blockquote style="' + abs + '">Quote text goes here.</blockquote>' });
    bm.add('list-ul', { label: 'Bullet List', category: 'Text', content: '<ul style="' + abs + '"><li>First item</li><li>Second item</li><li>Third item</li></ul>' });
    bm.add('list-ol', { label: 'Numbered List', category: 'Text', content: '<ol style="' + abs + '"><li>First item</li><li>Second item</li><li>Third item</li></ol>' });
    bm.add('divider', { label: 'Divider', category: 'Layout', content: '<hr style="' + abs + 'width:80%;border:none;border-top:1px solid #ddd;margin:0;" />' });
    bm.add('two-columns', { label: '2 Columns', category: 'Layout', content: '<div style="' + abs + 'display:flex;gap:12px;width:80%;"><div style="flex:1;"><p>Left</p></div><div style="flex:1;"><p>Right</p></div></div>' });
    bm.add('three-columns', { label: '3 Columns', category: 'Layout', content: '<div style="' + abs + 'display:flex;gap:12px;width:80%;"><div style="flex:1;"><p>Col 1</p></div><div style="flex:1;"><p>Col 2</p></div><div style="flex:1;"><p>Col 3</p></div></div>' });
    bm.add('text-placeholder', { label: 'Text Placeholder', category: 'Elements', content: '<p style="' + abs + 'color:#6b7280;font-style:italic;">{{ variable_name }}</p>' });
    bm.add('image', { label: 'Image', category: 'Media', content: { type: 'image', style: { position: 'absolute', top: '10px', left: '10px', 'max-height': '80px', width: 'auto' } } });
    bm.add('table-simple', { label: 'Table', category: 'Media', content: '<table style="' + abs + '"><thead><tr><th>Header 1</th><th>Header 2</th><th>Header 3</th></tr></thead><tbody><tr><td>Cell 1</td><td>Cell 2</td><td>Cell 3</td></tr><tr><td>Cell 4</td><td>Cell 5</td><td>Cell 6</td></tr></tbody></table>' });
    bm.add('page-number', { label: 'Page #', category: 'Elements', content: { type: 'text', content: 'Page <span class="pageNumber"></span> of <span class="totalPages"></span>', style: { position: 'absolute', bottom: '10px', right: '10px', 'font-size': '9px', color: '#999' } } });

    mini.on('load', function() {
      var wrapper = mini.DomComponents.getWrapper();
      wrapper.setStyle({ position: 'relative', width: '100%', height: '100%', overflow: 'hidden' });

      // Hide panels and force canvas to fill the entire container (no top gap)
      var panelsEl = el.querySelector('.gjs-pn-panels');
      if (panelsEl) panelsEl.style.display = 'none';

      var editorEl = el.querySelector('.gjs-editor');
      if (editorEl) {
        editorEl.style.background = '#fff';
        editorEl.style.position = 'relative';
      }

      var cvCanvas = el.querySelector('.gjs-cv-canvas');
      if (cvCanvas) {
        cvCanvas.style.background = '#fff';
        cvCanvas.style.width = '100%';
        cvCanvas.style.height = '100%';
        cvCanvas.style.top = '0';
        cvCanvas.style.position = 'absolute';
      }

      var frame = mini.Canvas.getFrameEl();
      if (frame && frame.contentDocument) {
        var style = frame.contentDocument.createElement('style');
        style.textContent = HF_CANVAS_STYLES;
        frame.contentDocument.head.appendChild(style);
      }
    });

    // Clamp drag within wrapper bounds
    mini.on('component:drag:end', function(model) {
      var target = model && model.target ? model.target : model;
      if (!target || target.get('type') === 'wrapper') return;
      var tel = target.getEl();
      if (!tel) return;
      var wrapperEl = tel.closest('[data-gjs-type="wrapper"]');
      if (!wrapperEl) return;

      var wW = wrapperEl.clientWidth;
      var wH = wrapperEl.clientHeight;
      var st = target.getStyle();
      var l = parseInt(st.left) || 0;
      var t = parseInt(st.top) || 0;
      var w = tel.offsetWidth;
      var h = tel.offsetHeight;
      var upd = {};

      var maxW = wW - Math.max(l, 0);
      var maxH = wH - Math.max(t, 0);
      if (w > maxW) upd.width = maxW + 'px';
      if (h > maxH) upd.height = maxH + 'px';

      var eW = upd.width ? maxW : w;
      var eH = upd.height ? maxH : h;
      var cL = Math.max(0, Math.min(l, wW - eW));
      var cT = Math.max(0, Math.min(t, wH - eH));
      if (cL !== l) upd.left = cL + 'px';
      if (cT !== t) upd.top = cT + 'px';

      if (Object.keys(upd).length > 0) target.addStyle(upd);
    });

    // Clamp resize within wrapper bounds
    mini.on('component:resize', function() {
      var target = mini.getSelected();
      if (!target || target.get('type') === 'wrapper') return;
      var tel = target.getEl();
      if (!tel) return;
      var wrapperEl = tel.closest('[data-gjs-type="wrapper"]');
      if (!wrapperEl) return;

      var st = target.getStyle();
      var l = parseInt(st.left) || 0;
      var t = parseInt(st.top) || 0;
      var maxW = wrapperEl.clientWidth - Math.max(l, 0);
      var maxH = wrapperEl.clientHeight - Math.max(t, 0);
      var upd = {};
      if (tel.offsetWidth > maxW) upd.width = maxW + 'px';
      if (tel.offsetHeight > maxH) upd.height = maxH + 'px';
      if (Object.keys(upd).length > 0) target.addStyle(upd);
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

  window.PhoenixKitHooks.GrapesJSHFEditor = {
    mounted() {
      var self = this;
      self._editor = null;
      self._paperSize = 'a4';

      self.handleEvent("init-hf-editor", function(payload) {
        ensureGrapesJS(function() {
          if (self._editor) { try { self._editor.destroy(); } catch(_) {} }

          self._paperSize = payload.paper_size || 'a4';

          setTimeout(function() {
            self._editor = initPageAwareHFEditor({
              containerId: 'hf-editor',
              blocksId: 'hf-editor-blocks',
              type: payload.type || 'header',
              paperSize: self._paperSize,
              height: payload.height || '25mm'
            });

            if (self._editor) {
              var hideLoader = function() {
                var loader = document.getElementById('hf-editor-loading');
                if (loader) loader.style.display = 'none';
              };
              self._editor.on('load', hideLoader);
              // Fallback: hide spinner after 3s in case load event already fired
              setTimeout(hideLoader, 3000);

              if (payload.native) {
                setTimeout(function() { self._editor.loadProjectData(payload.native); }, 300);
              }
            }
          }, 100);
        });
      });

      // Height change listener — resize editor region on blur/enter
      var heightInput = document.getElementById('hf-height');
      if (heightInput) {
        heightInput.addEventListener('change', function() {
          updateHFLayout(self._paperSize, heightInput.value);
          if (self._editor) {
            requestAnimationFrame(function() { self._editor.refresh(); });
          }
        });
      }

      // Paper size change listener — resize entire page frame
      var paperSelect = document.getElementById('hf-paper-size');
      if (paperSelect) {
        paperSelect.addEventListener('change', function() {
          self._paperSize = paperSelect.value;
          var height = document.getElementById('hf-height')?.value || '25mm';
          updateHFLayout(self._paperSize, height);
          if (self._editor) {
            requestAnimationFrame(function() { self._editor.refresh(); });
          }
        });
      }

      // Save handler — include paper_size
      self.handleEvent("request-hf-save-data", function() {
        var data = getEditorData(self._editor);
        self.pushEvent("save_record", {
          name: document.getElementById('hf-name')?.value || '',
          html: data.html,
          css: data.css,
          native: data.native,
          height: document.getElementById('hf-height')?.value || '25mm',
          paper_size: document.getElementById('hf-paper-size')?.value || 'a4'
        });
      });
    },

    destroyed() {
      if (this._editor) { try { this._editor.destroy(); } catch(_) {} this._editor = null; }
    }
  };

  // Register hooks on existing liveSocket if available
  if (window.liveSocket && window.liveSocket.hooks) {
    window.liveSocket.hooks.GrapesJSTemplateEditor = window.PhoenixKitHooks.GrapesJSTemplateEditor;
    window.liveSocket.hooks.GrapesJSDocumentEditor = window.PhoenixKitHooks.GrapesJSDocumentEditor;
    window.liveSocket.hooks.GrapesJSHFEditor = window.PhoenixKitHooks.GrapesJSHFEditor;
  }
})();
