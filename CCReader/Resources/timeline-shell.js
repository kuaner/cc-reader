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
          function escapeHtmlText(s) {
            return String(s || '')
              .replace(/&/g, '&amp;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
              .replace(/"/g, '&quot;')
              .replace(/'/g, '&#39;');
          }

          marked.use({
            renderer: {
              // Disable raw HTML in markdown: render HTML blocks as plain text.
              html: function(html) {
                return escapeHtmlText(html);
              },
              image: function(href, title, text) {
                var url = (href || '').trim();
                // Timeline rendering: treat markdown images as links to avoid WKWebView
                // decoding issues (e.g. WebP) and reduce layout shifts.
                var safeUrl = escapeHtmlText(url);
                var safeLabel = safeUrl || 'image';
                return '<a href="' + safeUrl + '" target="_blank" rel="noreferrer noopener">[image: ' + safeLabel + ']</a>';
              }
            }
          });
        } catch (e) {
          // ignore configuration errors; fall back to default rendering
        }
      }

      node.innerHTML = marked.parse(decodeMarkdownBase64(source));
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

// CCReader Timeline shell APIs (stable entrypoints for Swift).
// Keep this file focused on DOM operations + enhancement + scroll behavior.
window.ccreader = window.ccreader || {};

function ccreaderGetTimeline() {
  return document.querySelector('.timeline');
}

function ccreaderEnhanceNode(node) {
  // Markdown render + highlight are idempotent via dataset flags.
  renderMarkdownIn(node);
  highlightCodeBlocksIn(node);
  // Code-block enhancement / copy-button enhancement live in injected scripts.
  if (typeof enhanceCodeBlocks === 'function') { enhanceCodeBlocks(node); }
  if (typeof enhanceMessageCopyButtons === 'function') { enhanceMessageCopyButtons(node); }
}

ccreader.scrollBottomStable = function() {
  // Keep scrolling until the document height stabilizes (layout may change due to images).
  var attempts = 0;
  var lastH = -1;

  function scrollStep() {
    attempts++;
    var h = document.documentElement.scrollHeight;

    var timeline = ccreaderGetTimeline();
    var lastNode = timeline ? timeline.lastElementChild : null;
    if (lastNode && typeof lastNode.scrollIntoView === 'function') {
      lastNode.scrollIntoView(false); // align to bottom
    } else {
      window.scrollTo(0, h);
    }

    if (attempts < 8 && h !== lastH) {
      lastH = h;
      window.requestAnimationFrame(scrollStep);
    } else {
      var finalTimeline = ccreaderGetTimeline();
      var finalLast = finalTimeline ? finalTimeline.lastElementChild : null;
      if (finalLast && typeof finalLast.scrollIntoView === 'function') {
        finalLast.scrollIntoView(false);
      } else {
        window.scrollTo(0, document.documentElement.scrollHeight);
      }
    }
  }

  window.requestAnimationFrame(scrollStep);
};

ccreader.replaceTimeline = function(html) {
  var timeline = ccreaderGetTimeline();
  if (!timeline) { return; }

  var temp = document.createElement('div');
  temp.innerHTML = html || '';

  var frag = document.createDocumentFragment();
  var inserted = [];
  while (temp.firstElementChild) {
    var node = temp.firstElementChild;
    inserted.push(node);
    frag.appendChild(node);
  }

  timeline.replaceChildren(frag);
  for (var i = 0; i < inserted.length; i++) {
    ccreaderEnhanceNode(inserted[i]);
  }

  ccreader.scrollBottomStable();
};

ccreader.prependOlder = function(html, opts) {
  opts = opts || {};

  var timeline = ccreaderGetTimeline();
  if (!timeline) { return; }

  var scrollHeightBefore = document.documentElement.scrollHeight;
  var scrollYBefore = window.scrollY;

  var temp = document.createElement('div');
  temp.innerHTML = html || '';

  var frag = document.createDocumentFragment();
  var inserted = [];
  while (temp.firstElementChild) {
    var node = temp.firstElementChild;
    inserted.push(node);
    frag.appendChild(node);
  }

  // Preserve the older bar at the very top if present.
  var olderBar = document.getElementById('load-older-bar');
  if (olderBar) {
    olderBar.after(frag);
  } else {
    timeline.insertBefore(frag, timeline.firstChild);
  }

  for (var i = 0; i < inserted.length; i++) {
    ccreaderEnhanceNode(inserted[i]);
  }

  var scrollHeightAfter = document.documentElement.scrollHeight;
  window.scrollTo(0, scrollYBefore + (scrollHeightAfter - scrollHeightBefore));

  if (opts.removeOlderBar) {
    var bar = document.getElementById('load-older-bar');
    if (bar) { bar.remove(); }
  }
};

ccreader.setWaitingIndicator = function(htmlOrEmpty) {
  var timeline = ccreaderGetTimeline();
  if (!timeline) { return; }

  var id = 'waiting-indicator';
  var el = document.getElementById(id);

  if (!htmlOrEmpty) {
    if (el) { el.remove(); }
    return;
  }

  if (el) {
    el.outerHTML = htmlOrEmpty;
  } else {
    var temp = document.createElement('div');
    temp.innerHTML = htmlOrEmpty;
    if (temp.firstElementChild) {
      timeline.appendChild(temp.firstElementChild);
    }
  }

  if (isNearBottom()) {
    window.scrollTo(0, document.body.scrollHeight);
  }
};

ccreader.setLoadOlderBar = function(htmlOrEmpty) {
  var timeline = ccreaderGetTimeline();
  if (!timeline) { return; }

  var id = 'load-older-bar';
  var el = document.getElementById(id);

  if (!htmlOrEmpty) {
    if (el) { el.remove(); }
    return;
  }

  if (el) {
    el.outerHTML = htmlOrEmpty;
  } else {
    var temp = document.createElement('div');
    temp.innerHTML = htmlOrEmpty;
    if (temp.firstElementChild) {
      timeline.insertBefore(temp.firstElementChild, timeline.firstChild);
    }
  }
};

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

