function decodeMarkdownBase64(source) {
  return decodeURIComponent(escape(window.atob(source)));
}

function renderMarkdownIn(root) {
  if (typeof marked === 'undefined') { return; }
  root.querySelectorAll('[data-markdown-base64]').forEach(function(node) {
    if (node.dataset.mdRendered === '1') { return; }
    var source = node.getAttribute('data-markdown-base64') || '';
    if (!source) { return; }
    try {
      // Configure marked once: avoid rendering problematic WebP images in WKWebView
      // (WebContent logs show WEBP decode failures). Render those as links instead.
      if (!window.__ccreader_marked_configured) {
        window.__ccreader_marked_configured = true;
        try {
          marked.use({
            renderer: {
              image: function(href, title, text) {
                var url = (href || '').trim();
                var label = (text || url || 'image').trim();
                var isWebp = /\.webp(\?|#|$)/i.test(url);
                if (isWebp) {
                  var safeUrl = (url || '').replace(/"/g, '&quot;');
                  return '<a href="' + safeUrl + '" target="_blank" rel="noreferrer noopener">[image: ' + label + ']</a>';
                }
                // default behavior: emit an <img>; attributes tuned post-parse below
                return false;
              }
            }
          });
        } catch (e) {
          // ignore configuration errors; fall back to default rendering
        }
      }

      node.innerHTML = marked.parse(decodeMarkdownBase64(source));

      // Lazy-load images to reduce late layout shifts.
      node.querySelectorAll('img').forEach(function(img) {
        if (!img) { return; }
        if (!img.getAttribute('loading')) { img.setAttribute('loading', 'lazy'); }
        img.setAttribute('decoding', 'async');
      });
      node.dataset.mdRendered = '1';
    } catch (e) {
      console.error('markdown render failed', e);
    }
  });
}

function highlightCodeBlocksIn(root) {
  if (typeof hljs === 'undefined') { return; }
  root.querySelectorAll('pre code').forEach(function(block) {
    if (block.dataset.hlRendered === '1') { return; }
    try {
      hljs.highlightElement(block);
      block.dataset.hlRendered = '1';
    } catch (e) {
      console.error('highlight failed', e);
    }
  });
}

function isNearBottom() {
  return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - __FOLLOW_BOTTOM_THRESHOLD__;
}

var scrollState = { followingBottom: true, ticking: false };

function emitScrollState() {
  var following = isNearBottom();
  if (following !== scrollState.followingBottom) {
    scrollState.followingBottom = following;
    window.webkit.messageHandlers.ccreader.postMessage({
      action: 'scrollState',
      following: following
    });
  }
}

window.addEventListener('scroll', function() {
  if (scrollState.ticking) { return; }
  scrollState.ticking = true;
  window.requestAnimationFrame(function() {
    scrollState.ticking = false;
    emitScrollState();
  });
}, { passive: true });

// Initial render
renderMarkdownIn(document);
highlightCodeBlocksIn(document);
enhanceCodeBlocks(document);
enhanceMessageCopyButtons(document);
window.scrollTo(0, document.body.scrollHeight);

