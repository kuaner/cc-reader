function decodeMarkdownBase64(source) {
  return decodeURIComponent(escape(window.atob(source)));
}

function renderMarkdownIn(root) {
  if (typeof marked === 'undefined') { return; }
  root.querySelectorAll('[data-markdown-base64]').forEach(function (node) {
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

          function markedValue(input, preferredKey) {
            if (typeof input === 'string') { return input; }
            if (!input || typeof input !== 'object') { return ''; }
            if (preferredKey && typeof input[preferredKey] === 'string') { return input[preferredKey]; }
            if (typeof input.raw === 'string') { return input.raw; }
            if (typeof input.text === 'string') { return input.text; }
            if (typeof input.href === 'string') { return input.href; }
            return '';
          }

          marked.use({
            renderer: {
              // Disable raw HTML in markdown: render HTML blocks as plain text.
              html: function (html) {
                return escapeHtmlText(markedValue(html, 'text'));
              },
              image: function (href, title, text) {
                var url = markedValue(href, 'href').trim();
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
  root.querySelectorAll('pre code').forEach(function (block) {
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

function ccreaderEscapeHTML(s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function ccreaderEncodeBase64Utf8(s) {
  return window.btoa(unescape(encodeURIComponent(String(s || ''))));
}

function ccreaderMessageBodyHTML(text) {
  var source = String(text || '');
  if (!source) { return ''; }
  var fallback = ccreaderEscapeHTML(source).replace(/\n/g, '<br>');
  var encoded = ccreaderEncodeBase64Utf8(source);
  return '<div class="markdown" data-markdown-base64="' + encoded + '"><div class="plain-text">' + fallback + '</div></div>';
}

function ccreaderMessageRawDataButtonHTML(payload) {
  var raw = String(payload.rawData || '');
  if (!raw) { return ''; }
  var encoded = ccreaderEncodeBase64Utf8(raw);
  var rawLabel = ccreaderEscapeHTML(payload.rawDataLabel || 'Raw Data');
  return '<button type="button" class="message-copy-button" data-message-copy-base64="' + encoded + '" data-copy-label="' + rawLabel + '">' + rawLabel + '</button>';
}

function ccreaderRenderMessageFromPayload(payload) {
  var domId = ccreaderEscapeHTML(payload.domId || '');
  var timestamp = ccreaderEscapeHTML(payload.timeLabel || '');
  var copyButton = ccreaderMessageRawDataButtonHTML(payload);

  if (payload.isUser) {
    if (payload.isSummary) {
      var summaryTag = '<span class="type-tag summary-tag">' + ccreaderEscapeHTML(payload.legendSummary || 'Summary') + '</span>';
      var summaryFooter = '<div class="bubble-footer"><span>' + timestamp + '</span>' + summaryTag + '<span class="spacer"></span>' + copyButton + '</div>';
      var summaryBubble = '<div class="bubble summary"><div class="summary-title">' + ccreaderEscapeHTML(payload.summaryLabel || 'Summary') + '</div>' + ccreaderMessageBodyHTML(payload.content || '') + summaryFooter + '</div>';
      return '<div class="row user" id="' + domId + '"><div class="stack">' + summaryBubble + '</div></div>';
    }

    var userTag = '<span class="type-tag user-tag">' + ccreaderEscapeHTML(payload.legendUser || 'User') + '</span>';
    var userFooter = '<div class="bubble-footer"><span>' + timestamp + '</span>' + userTag + '<span class="spacer"></span>' + copyButton + '</div>';
    var userBubble = '<div class="bubble user">' + ccreaderMessageBodyHTML(payload.content || '') + userFooter + '</div>';
    return '<div class="row user" id="' + domId + '"><div class="stack">' + userBubble + '</div></div>';
  }

  var sections = [];
  var assistantTitle = ccreaderEscapeHTML(payload.assistantLabel || 'Assistant');
  var model = payload.modelTitle ? '<span class="pill">' + ccreaderEscapeHTML(payload.modelTitle) + '</span>' : '';
  sections.push('<div class="assistant-header"><span class="assistant-title">' + assistantTitle + '</span>' + model + '</div>');

  if (payload.thinking) {
    sections.push('<div class="card-section thinking"><div class="section-title">' + ccreaderEscapeHTML(payload.thinkingTitle || 'Thinking') + '</div>' + ccreaderMessageBodyHTML(payload.thinking) + '</div>');
  }

  var tools = Array.isArray(payload.tools) ? payload.tools : [];
  if (tools.length > 0) {
    var toolBody = tools.map(function (tool) {
      var title = ccreaderEscapeHTML(tool.title || '');
      var body = tool.body ? '<pre class="plain-pre">' + ccreaderEscapeHTML(tool.body) + '</pre>' : '';
      return '<div><div class="section-title">' + title + '</div>' + body + '</div>';
    }).join('');
    sections.push('<div class="card-section tool"><div class="section-title">' + ccreaderEscapeHTML(payload.contextLabel || 'Context') + '</div>' + toolBody + '</div>');
  }

  if (payload.content) {
    sections.push('<div class="card-section">' + ccreaderMessageBodyHTML(payload.content) + '</div>');
  }

  var assistantTag = '<span class="type-tag assistant-tag">' + ccreaderEscapeHTML(payload.legendAssistant || 'Assistant') + '</span>';
  sections.push('<div class="bubble-footer"><span>' + timestamp + '</span>' + assistantTag + '<span class="spacer"></span>' + copyButton + '</div>');
  return '<div class="row assistant" id="' + domId + '"><div class="stack"><div class="bubble assistant-card">' + sections.join('') + '</div></div></div>';
}

function ccreaderEnhanceNode(node) {
  // Markdown render + highlight are idempotent via dataset flags.
  renderMarkdownIn(node);
  highlightCodeBlocksIn(node);
  // Code-block enhancement / copy-button enhancement live in injected scripts.
  if (typeof enhanceCodeBlocks === 'function') { enhanceCodeBlocks(node); }
  if (typeof enhanceMessageCopyButtons === 'function') { enhanceMessageCopyButtons(node); }
}

ccreader.scrollBottomStable = function () {
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

ccreader.replaceTimeline = function (html) {
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

ccreader.replaceMessageById = function (domId, html) {
  var id = String(domId || '');
  if (!id) { return; }

  var existing = document.getElementById(id);
  if (!existing) { return; }

  var temp = document.createElement('div');
  temp.innerHTML = html || '';
  var newNode = temp.firstElementChild;
  if (!newNode) { return; }

  existing.replaceWith(newNode);
  ccreaderEnhanceNode(newNode);
};

ccreader.appendMessages = function (html) {
  var timeline = ccreaderGetTimeline();
  if (!timeline) { return; }

  var waiting = document.getElementById('waiting-indicator');
  var wasAtBottom = isNearBottom();

  var temp = document.createElement('div');
  temp.innerHTML = html || '';

  var inserted = [];
  while (temp.firstElementChild) {
    var node = temp.firstElementChild;
    if (waiting) {
      timeline.insertBefore(node, waiting);
    } else {
      timeline.appendChild(node);
    }
    inserted.push(node);
  }

  for (var i = 0; i < inserted.length; i++) {
    ccreaderEnhanceNode(inserted[i]);
  }

  if (wasAtBottom) {
    window.scrollTo(0, document.body.scrollHeight);
  }
};

ccreader.replaceMessagesFromPayload = function (payloads) {
  if (!Array.isArray(payloads) || payloads.length === 0) { return; }
  for (var i = 0; i < payloads.length; i++) {
    var payload = payloads[i];
    var domId = payload && payload.domId;
    if (!domId) { continue; }
    ccreader.replaceMessageById(domId, ccreaderRenderMessageFromPayload(payload));
  }
};

ccreader.appendMessagesFromPayload = function (payloads) {
  if (!Array.isArray(payloads) || payloads.length === 0) { return; }
  var html = payloads.map(function (payload) {
    return ccreaderRenderMessageFromPayload(payload);
  }).join('\n');
  ccreader.appendMessages(html);
};

/** Full timeline replace: message rows from payloads + optional top load-older bar + optional waiting row (HTML from Swift for chrome). */
ccreader.replaceTimelineFromPayloads = function (opts) {
  opts = opts || {};
  var payloads = Array.isArray(opts.messages) ? opts.messages : [];
  var htmlParts = payloads.map(function (p) {
    return ccreaderRenderMessageFromPayload(p);
  });
  var html = String(opts.loadOlderBarHTML || '') + htmlParts.join('\n') + String(opts.waitingHTML || '');
  ccreader.replaceTimeline(html);
};

/** Prepend older message rows from payloads; same scroll + older-bar removal behavior as prependOlder. */
ccreader.prependOlderFromPayloads = function (opts) {
  opts = opts || {};
  var payloads = Array.isArray(opts.messages) ? opts.messages : [];
  var html = payloads.map(function (p) {
    return ccreaderRenderMessageFromPayload(p);
  }).join('\n');
  var prependOpts = {};
  if (opts.removeOlderBar) {
    prependOpts.removeOlderBar = true;
  }
  ccreader.prependOlder(html, prependOpts);
};

ccreader.prependOlder = function (html, opts) {
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

ccreader.setWaitingIndicator = function (htmlOrEmpty) {
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

ccreader.setLoadOlderBar = function (htmlOrEmpty) {
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

window.addEventListener('scroll', function () {
  if (scrollState.ticking) { return; }
  scrollState.ticking = true;
  window.requestAnimationFrame(function () {
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

