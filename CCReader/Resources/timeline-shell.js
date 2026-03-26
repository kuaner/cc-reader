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

