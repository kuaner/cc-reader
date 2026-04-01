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

function ccreaderMessageBodyHTML(text, options) {
  options = options || {};
  var preserveLineBreaks = options.preserveLineBreaks === true;
  var renderMarkdown = options.renderMarkdown !== false;
  var source = String(text || '');
  if (!source) { return ''; }
  if (preserveLineBreaks || !renderMarkdown) {
    return '<div class="plain-text preserve-lines">' + ccreaderEscapeHTML(source) + '</div>';
  }
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

function ccreaderTypeTagsHTML(payload, fallbackLabel, kindClass) {
  var tags = Array.isArray(payload.metaTags) ? payload.metaTags : [];
  if (tags.length === 0) {
    var fallback = ccreaderEscapeHTML(fallbackLabel || 'Assistant');
    var klass = kindClass ? ' ' + kindClass : '';
    return '<span class="type-tag' + klass + '">' + fallback + '</span>';
  }
  var resolvedClass = kindClass ? ' ' + kindClass : '';
  return tags.map(function (tag) {
    var token = String(tag || '').toLowerCase();
    var semanticClass = '';
    if (!payload.isUser && token === 'tool_use') {
      semanticClass = ' tool-use-tag';
    } else if (payload.isUser && token === 'tool_result') {
      semanticClass = ' tool-result-tag';
    }
    return '<span class="type-tag' + resolvedClass + semanticClass + '">' + ccreaderEscapeHTML(tag) + '</span>';
  }).join('');
}

function ccreaderLooksLikeMarkdown(text) {
  var source = String(text || '');
  if (!source) { return false; }
  // Common markdown markers: fenced code, headings, list items, links/images, tables, blockquotes.
  return /```|^\s{0,3}#{1,6}\s|^\s*[-*+]\s|^\s*\d+\.\s|\[[^\]]+\]\([^)]+\)|!\[[^\]]*\]\([^)]+\)|^\s*>\s|^\s*\|.+\|/m.test(source);
}

function ccreaderToolResultImagesHTML(payload) {
  var images = Array.isArray(payload.resultImages) ? payload.resultImages : [];
  if (images.length === 0) { return ''; }
  var body = images.map(function (item) {
    var base64 = String((item && item.base64) || '');
    if (!base64) { return ''; }
    var mediaType = ccreaderEscapeHTML(String((item && item.mediaType) || 'image/png'));
    return '<div class="result-image-item"><img class="result-image" src="data:' + mediaType + ';base64,' + base64 + '" loading="lazy" /></div>';
  }).join('');
  if (!body) { return ''; }
  return '<div class="result-images">' + body + '</div>';
}

function ccreaderRenderMessageFromPayload(payload) {
  var domId = ccreaderEscapeHTML(payload.domId || '');
  var timestamp = ccreaderEscapeHTML(payload.timeLabel || '');
  var copyButton = ccreaderMessageRawDataButtonHTML(payload);

  if (payload.isCompactSummary) {
    var summaryContent = ccreaderMessageBodyHTML(payload.content || '');
    var summaryTag = '<span class="type-tag summary-tag">' + ccreaderEscapeHTML(payload.legendSummary || 'Summary') + '</span>';
    var footer = '<div class="bubble-footer"><span>' + timestamp + '</span>' + summaryTag + '<span class="spacer"></span>' + copyButton + '</div>';
    return '<div class="row compact-summary-row" id="' + domId + '"><div class="stack"><div class="bubble compact-summary-bubble"><div class="compact-summary-icon">&#x21BB;</div><div class="compact-summary-content"><div class="compact-summary-title">' + ccreaderEscapeHTML(payload.summaryLabel || 'Conversation summarized') + '</div>' + summaryContent + '</div>' + footer + '</div></div></div>';
  }

  if (payload.isApiError) {
    var errorTag = '<span class="type-tag error-tag">' + ccreaderEscapeHTML(payload.legendLabel) + '</span>';
    var retryTag = payload.specialTag ? '<span class="type-tag error-tag">' + ccreaderEscapeHTML(payload.specialTag) + '</span>' : '';
    var footer = '<div class="bubble-footer"><span>' + timestamp + '</span>' + errorTag + retryTag + '<span class="spacer"></span>' + copyButton + '</div>';
    return '<div class="row api-error-row" id="' + domId + '"><div class="stack"><div class="bubble api-error-bubble">' + footer + '</div></div></div>';
  }

  if (payload.isUser) {
    var userTags = Array.isArray(payload.metaTags) ? payload.metaTags : [];
    var hasToolResultTag = userTags.some(function (tag) {
      return String(tag || '').toLowerCase() === 'tool_result';
    });
    var toolResultShouldRenderMarkdown = hasToolResultTag && ccreaderLooksLikeMarkdown(payload.content || '');
    var userBody = hasToolResultTag
      ? ccreaderMessageBodyHTML(payload.content || '', {
          preserveLineBreaks: !toolResultShouldRenderMarkdown,
          renderMarkdown: toolResultShouldRenderMarkdown
        })
      : ccreaderMessageBodyHTML(payload.content || '');
    var userImages = ccreaderToolResultImagesHTML(payload);
    var userBodyWithImages = userBody + userImages;

    if (payload.isSummary) {
      var summaryTag = '<span class="type-tag summary-tag">' + ccreaderEscapeHTML(payload.legendSummary || 'Summary') + '</span>';
      var summaryFooter = '<div class="bubble-footer"><span>' + timestamp + '</span>' + summaryTag + '<span class="spacer"></span>' + copyButton + '</div>';
      var summaryBubble = '<div class="bubble summary"><div class="summary-title">' + ccreaderEscapeHTML(payload.summaryLabel || 'Summary') + '</div>' + userBodyWithImages + summaryFooter + '</div>';
      return '<div class="row user" id="' + domId + '"><div class="stack">' + summaryBubble + '</div></div>';
    }

    var userTagsHTML = ccreaderTypeTagsHTML(payload, payload.legendUser || 'User', 'user-tag');
    var agentIdHTML = payload.specialTag ? '<a class="pill agent-id" data-cc-session-id="' + ccreaderEscapeHTML(payload.specialTag) + '">' + ccreaderEscapeHTML(payload.specialTag) + '</a>' : '';
    var userFooter = '<div class="bubble-footer"><span>' + timestamp + '</span>' + userTagsHTML + agentIdHTML + '<span class="spacer"></span>' + copyButton + '</div>';
    var userBubble = '<div class="bubble user">' + userBodyWithImages + userFooter + '</div>';
    return '<div class="row user" id="' + domId + '"><div class="stack">' + userBubble + '</div></div>';
  }

  var sections = [];
  var isAgentDispatch = payload.bubbleKind === 'agent_dispatch';
  var isToolOnly = payload.renderMode === 'tool_only';
  var useFlatToolBody = isAgentDispatch || isToolOnly;
  var assistantTitle = ccreaderEscapeHTML(payload.assistantLabel || 'Assistant');
  var specialTag = (!isAgentDispatch && payload.specialTag) ? '<span class="pill special">' + ccreaderEscapeHTML(payload.specialTag) + '</span>' : '';
  var model = payload.modelTitle ? '<span class="pill">' + ccreaderEscapeHTML(payload.modelTitle) + '</span>' : '';
  sections.push('<div class="assistant-header"><span class="assistant-title">' + assistantTitle + '</span>' + specialTag + model + '</div>');

  if (payload.thinking) {
    sections.push('<div class="card-section thinking"><div class="section-title">' + ccreaderEscapeHTML(payload.thinkingTitle || 'Thinking') + '</div>' + ccreaderMessageBodyHTML(payload.thinking) + '</div>');
  }

  var tools = Array.isArray(payload.tools) ? payload.tools : [];
  if (tools.length > 0) {
    var toolBody = tools.map(function (tool) {
      var title = ccreaderEscapeHTML(tool.title || '');
      var body = '';
      var renderStyle = String(tool.renderStyle || '');
      if (tool.body) {
        if (renderStyle === 'markdown') {
          body = ccreaderMessageBodyHTML(tool.body);
        } else {
          body = '<pre class="plain-pre">' + ccreaderEscapeHTML(tool.body) + '</pre>';
        }
      }
      return '<div><div class="section-title">' + title + '</div>' + body + '</div>';
    }).join('');
    if (useFlatToolBody) {
      sections.push('<div class="card-section tool-flat-body">' + toolBody + '</div>');
    } else {
      sections.push('<div class="card-section tool"><div class="section-title">' + ccreaderEscapeHTML(payload.contextLabel || 'Context') + '</div>' + toolBody + '</div>');
    }
  }

  if (payload.content) {
    sections.push('<div class="card-section">' + ccreaderMessageBodyHTML(payload.content) + '</div>');
  }

  var assistantTagKindClass = isAgentDispatch ? 'dispatch-tag' : 'assistant-tag';
  var assistantTags = ccreaderTypeTagsHTML(payload, payload.legendLabel || payload.legendAssistant || 'Assistant', assistantTagKindClass);
  var bubbleKindClass = '';
  if (payload.bubbleKind === 'agent_dispatch') {
    bubbleKindClass = ' agent-dispatch';
  }
  sections.push('<div class="bubble-footer"><span>' + timestamp + '</span>' + assistantTags + '<span class="spacer"></span>' + copyButton + '</div>');
  return '<div class="row assistant" id="' + domId + '"><div class="stack"><div class="bubble assistant-card' + bubbleKindClass + '">' + sections.join('') + '</div></div></div>';
}

function ccreaderEnhanceNode(node) {
  // Markdown render + highlight are idempotent via dataset flags.
  renderMarkdownIn(node);
  highlightCodeBlocksIn(node);
  // Code-block enhancement / copy-button enhancement live in injected scripts.
  if (typeof enhanceCodeBlocks === 'function') { enhanceCodeBlocks(node); }
  if (typeof enhanceMessageCopyButtons === 'function') { enhanceMessageCopyButtons(node); }
}

function ccreaderRenderRowsFromPayloads(payloads) {
  if (!Array.isArray(payloads) || payloads.length === 0) { return ''; }
  return payloads.map(function (payload) {
    return ccreaderRenderMessageFromPayload(payload);
  }).join('\n');
}

function ccreaderParseNodesFromHTML(html) {
  var temp = document.createElement('div');
  temp.innerHTML = html || '';
  var nodes = [];
  while (temp.firstElementChild) {
    var node = temp.firstElementChild;
    nodes.push(node);
    temp.removeChild(node);
  }
  return nodes;
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

  var frag = document.createDocumentFragment();
  var inserted = ccreaderParseNodesFromHTML(html);
  for (var i = 0; i < inserted.length; i++) {
    var node = inserted[i];
    frag.appendChild(node);
  }

  timeline.replaceChildren(frag);
  for (var j = 0; j < inserted.length; j++) {
    ccreaderEnhanceNode(inserted[j]);
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

  var inserted = ccreaderParseNodesFromHTML(html);
  for (var i = 0; i < inserted.length; i++) {
    var node = inserted[i];
    if (waiting) {
      timeline.insertBefore(node, waiting);
    } else {
      timeline.appendChild(node);
    }
  }

  for (var j = 0; j < inserted.length; j++) {
    ccreaderEnhanceNode(inserted[j]);
  }

  if (wasAtBottom) {
    window.scrollTo(0, document.body.scrollHeight);
  }
};

ccreader.replaceMessagesFromPayload = function (payloads) {
  if (!Array.isArray(payloads) || payloads.length === 0) { return; }
  // Stub → full content swaps grow document height without changing scrollY; user ends up
  // mid-page unless we re-anchor (same idea as appendMessages + wasAtBottom).
  var wasAtBottom = isNearBottom();
  for (var i = 0; i < payloads.length; i++) {
    var payload = payloads[i];
    var domId = payload && payload.domId;
    if (!domId) { continue; }
    ccreader.replaceMessageById(domId, ccreaderRenderMessageFromPayload(payload));
  }
  if (wasAtBottom) {
    ccreader.scrollBottomStable();
  }
};

ccreader.appendMessagesFromPayload = function (payloads) {
  var html = ccreaderRenderRowsFromPayloads(payloads);
  if (!html) { return; }
  ccreader.appendMessages(html);
};

/** Full timeline replace: message rows from payloads + optional top load-older bar + optional waiting row (HTML from Swift for chrome). */
ccreader.replaceTimelineFromPayloads = function (opts) {
  opts = opts || {};
  var payloads = Array.isArray(opts.messages) ? opts.messages : [];
  var rowHTML = ccreaderRenderRowsFromPayloads(payloads);
  var html = String(opts.loadOlderBarHTML || '') + rowHTML + String(opts.waitingHTML || '');
  ccreader.replaceTimeline(html);
};

/**
 * Progressive replace for session switch:
 * 1) Render latest tail first (fast first paint)
 * 2) Prepend remaining older rows chunk-by-chunk
 */
ccreader.replaceTimelineFromPayloadsProgressive = function (opts) {
  opts = opts || {};
  var payloads = Array.isArray(opts.messages) ? opts.messages : [];
  if (payloads.length === 0) {
    ccreader.replaceTimelineFromPayloads(opts);
    return;
  }

  // Defaults only if Swift omits keys (normally `TimelineHostView` passes these).
  var initialLatestCount = Number(opts.initialLatestCount || 18);
  var prependChunkSize = Number(opts.prependChunkSize || 16);
  initialLatestCount = Math.max(1, initialLatestCount);
  prependChunkSize = Math.max(1, prependChunkSize);

  var tailStart = Math.max(0, payloads.length - initialLatestCount);
  var latestTail = payloads.slice(tailStart);
  ccreader.replaceTimelineFromPayloads({
    messages: latestTail,
    loadOlderBarHTML: opts.loadOlderBarHTML,
    waitingHTML: opts.waitingHTML
  });

  var olderHead = payloads.slice(0, tailStart);
  if (olderHead.length === 0) { return; }

  var cursor = olderHead.length;
  function prependStep() {
    if (cursor <= 0) { return; }
    var start = Math.max(0, cursor - prependChunkSize);
    var chunk = olderHead.slice(start, cursor);
    ccreader.prependOlderFromPayloads({ messages: chunk, removeOlderBar: false });
    cursor = start;
    if (cursor > 0) {
      window.requestAnimationFrame(prependStep);
    }
  }

  window.requestAnimationFrame(prependStep);
};

/** Prepend older message rows from payloads; same scroll + older-bar removal behavior as prependOlder. */
ccreader.prependOlderFromPayloads = function (opts) {
  opts = opts || {};
  var payloads = Array.isArray(opts.messages) ? opts.messages : [];
  var html = ccreaderRenderRowsFromPayloads(payloads);
  if (!html) { return; }
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

  var frag = document.createDocumentFragment();
  var inserted = ccreaderParseNodesFromHTML(html);
  for (var i = 0; i < inserted.length; i++) {
    var node = inserted[i];
    frag.appendChild(node);
  }

  // Preserve the older bar at the very top if present.
  var olderBar = document.getElementById('load-older-bar');
  if (olderBar) {
    olderBar.after(frag);
  } else {
    timeline.insertBefore(frag, timeline.firstChild);
  }

  for (var j = 0; j < inserted.length; j++) {
    ccreaderEnhanceNode(inserted[j]);
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
    var nodes = ccreaderParseNodesFromHTML(htmlOrEmpty);
    if (nodes.length > 0) {
      timeline.appendChild(nodes[0]);
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
    var nodes = ccreaderParseNodesFromHTML(htmlOrEmpty);
    if (nodes.length > 0) {
      timeline.insertBefore(nodes[0], timeline.firstChild);
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

document.addEventListener('click', function (e) {
  var pill = e.target.closest('.agent-id[data-cc-session-id]');
  if (pill) {
    var sessionId = pill.getAttribute('data-cc-session-id');
    if (sessionId) {
      window.webkit.messageHandlers.ccreader.postMessage({action: 'navigateToSession', sessionId: sessionId});
    }
  }
});

// Initial render
renderMarkdownIn(document);
highlightCodeBlocksIn(document);
enhanceCodeBlocks(document);
enhanceMessageCopyButtons(document);
window.scrollTo(0, document.body.scrollHeight);

