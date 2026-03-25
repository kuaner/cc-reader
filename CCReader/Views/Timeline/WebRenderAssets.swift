import Foundation

enum WebRenderResourceLoader {
    static func text(named name: String, extension ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

enum MarkedJavaScriptLoader {
    private static var cachedScript: String?

    static var script: String {
        if let cachedScript {
            return cachedScript
        }
        let script = WebRenderResourceLoader.text(named: "marked.min", extension: "js")
        cachedScript = script
        return script
    }
}

enum HighlightJavaScriptLoader {
    private static var cachedScript: String?

    static var script: String {
        if let cachedScript {
            return cachedScript
        }
        let script = WebRenderResourceLoader.text(named: "highlight.min", extension: "js")
        cachedScript = script
        return script
    }
}

enum HighlightThemeLoader {
    private static var cachedStylesheet: String?

    static var stylesheet: String {
        if let cachedStylesheet {
            return cachedStylesheet
        }

        let light = WebRenderResourceLoader.text(named: "highlight-light", extension: "css")
        let dark = WebRenderResourceLoader.text(named: "highlight-dark", extension: "css")

        let stylesheet = """
        @media (prefers-color-scheme: light) {
        \(light)
        }
        @media (prefers-color-scheme: dark) {
        \(dark)
        }
        """

        cachedStylesheet = stylesheet
        return stylesheet
    }
}

enum WebRenderChrome {
    static var codeBlockStylesheet: String {
        """
        .code-block {
          margin: 0.85em 0;
          border: 1px solid var(--code-block-border);
          border-radius: 12px;
          overflow: hidden;
          background: var(--code-bg);
        }
        .code-block-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 10px;
          padding: 8px 12px;
          background: var(--code-header-bg);
          border-bottom: 1px solid var(--code-header-border);
        }
        .code-block-language {
          font-size: 11px;
          font-weight: 600;
          letter-spacing: 0.08em;
          text-transform: uppercase;
          color: var(--muted);
        }
        .code-copy-button {
          appearance: none;
          border: 1px solid var(--code-button-border);
          background: var(--code-button-bg);
          color: inherit;
          font: inherit;
          font-size: 11px;
          line-height: 1.2;
          border-radius: 999px;
          padding: 4px 9px;
          cursor: pointer;
          transition: background 0.18s ease, border-color 0.18s ease, color 0.18s ease;
        }
        .code-copy-button:hover {
          background: color-mix(in srgb, var(--code-button-bg) 65%, var(--text));
        }
        .code-copy-button.is-copied {
          color: #16a34a;
          border-color: rgba(22, 163, 74, 0.28);
        }
        .code-block-body {
          overflow-x: auto;
        }
        .markdown .code-block pre {
          margin: 0;
          border-radius: 0;
          padding: 14px;
          overflow: visible;
        }
        .markdown .code-block pre code {
          display: block;
          min-width: max-content;
        }
        """
    }

        static var messageActionStylesheet: String {
                """
                .message-copy-button {
                    appearance: none;
                    border: 1px solid var(--message-button-border);
                    background: var(--message-button-bg);
                    color: inherit;
                    font: inherit;
                    font-size: 11px;
                    line-height: 1.2;
                    border-radius: 999px;
                    padding: 4px 9px;
                    cursor: pointer;
                    transition: background 0.18s ease, border-color 0.18s ease, color 0.18s ease;
                }
                .message-copy-button:hover {
                    background: color-mix(in srgb, var(--message-button-bg) 55%, var(--text));
                }
                .message-copy-button.is-copied {
                    color: #16a34a;
                    border-color: rgba(22, 163, 74, 0.28);
                }
                .bubble.user .message-copy-button {
                    border-color: rgba(255,255,255,0.18);
                    background: rgba(255,255,255,0.10);
                    color: rgba(255,255,255,0.96);
                }
                .bubble.user .message-copy-button:hover {
                    background: rgba(255,255,255,0.18);
                }
                """
        }

    static func codeBlockEnhancementScript(copyLabel: String = "Copy", copiedLabel: String = "Copied") -> String {
        let escapedCopyLabel = escapeJavaScript(copyLabel)
        let escapedCopiedLabel = escapeJavaScript(copiedLabel)

        return """
        function detectCodeLanguage(block) {
            if (!block) { return ''; }
            const classNames = Array.from(block.classList || []);
            for (const className of classNames) {
                if (className.startsWith('language-')) {
                    return className.slice(9);
                }
                if (className.startsWith('lang-')) {
                    return className.slice(5);
                }
            }
            return block.getAttribute('data-language') || '';
        }

        function prettifyCodeLanguage(rawLanguage) {
            const normalized = (rawLanguage || '').toLowerCase();
            if (!normalized) { return 'Code'; }

            const aliases = {
                js: 'JavaScript',
                jsx: 'JSX',
                ts: 'TypeScript',
                tsx: 'TSX',
                py: 'Python',
                sh: 'Shell',
                shell: 'Shell',
                zsh: 'Zsh',
                bash: 'Bash',
                swift: 'Swift',
                objc: 'Objective-C',
                json: 'JSON',
                yml: 'YAML',
                yaml: 'YAML',
                md: 'Markdown',
                html: 'HTML',
                xml: 'XML',
                css: 'CSS',
                scss: 'SCSS',
                sql: 'SQL',
                text: 'Text',
                plaintext: 'Text',
                txt: 'Text'
            };

            if (aliases[normalized]) {
                return aliases[normalized];
            }

            return normalized
                .split(/[-_]/g)
                .filter(Boolean)
                .map(function(part) {
                    return part.charAt(0).toUpperCase() + part.slice(1);
                })
                .join(' ');
        }

        function fallbackCopyText(text) {
            return new Promise(function(resolve, reject) {
                try {
                    const textArea = document.createElement('textarea');
                    textArea.value = text;
                    textArea.setAttribute('readonly', 'readonly');
                    textArea.style.position = 'fixed';
                    textArea.style.opacity = '0';
                    textArea.style.pointerEvents = 'none';
                    document.body.appendChild(textArea);
                    textArea.focus();
                    textArea.select();
                    const successful = document.execCommand('copy');
                    document.body.removeChild(textArea);
                    if (successful) {
                        resolve();
                        return;
                    }
                    reject(new Error('execCommand copy failed'));
                } catch (error) {
                    reject(error);
                }
            });
        }

        function copyCodeText(text) {
            if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
                return navigator.clipboard.writeText(text).catch(function() {
                    return fallbackCopyText(text);
                });
            }
            return fallbackCopyText(text);
        }

        function enhanceCodeBlocks(root) {
            if (!root || typeof root.querySelectorAll !== 'function') { return; }
            root.querySelectorAll('pre code').forEach(function(block) {
                const pre = block.parentElement;
                if (!pre || (pre.parentElement && pre.parentElement.classList.contains('code-block-body'))) {
                    return;
                }

                const wrapper = document.createElement('div');
                wrapper.className = 'code-block';

                const header = document.createElement('div');
                header.className = 'code-block-header';

                const language = document.createElement('span');
                language.className = 'code-block-language';
                language.textContent = prettifyCodeLanguage(detectCodeLanguage(block));

                const button = document.createElement('button');
                button.type = 'button';
                button.className = 'code-copy-button';
                button.textContent = '\(escapedCopyLabel)';
                button.addEventListener('click', function() {
                    const codeText = block.innerText || block.textContent || '';
                    copyCodeText(codeText).then(function() {
                        button.textContent = '\(escapedCopiedLabel)';
                        button.classList.add('is-copied');
                        window.setTimeout(function() {
                            button.textContent = '\(escapedCopyLabel)';
                            button.classList.remove('is-copied');
                        }, 1600);
                    }).catch(function(error) {
                        console.error('copy code failed', error);
                    });
                });

                header.appendChild(language);
                header.appendChild(button);

                const body = document.createElement('div');
                body.className = 'code-block-body';

                pre.parentNode.insertBefore(wrapper, pre);
                body.appendChild(pre);
                wrapper.appendChild(header);
                wrapper.appendChild(body);
            });
        }
        """
    }

    static func messageCopyEnhancementScript(copiedLabel: String = "Copied", resetLabelFromDataAttribute: Bool = true) -> String {
        let escapedCopiedLabel = escapeJavaScript(copiedLabel)
        let resetFromDataAttribute = resetLabelFromDataAttribute ? "true" : "false"

        return """
        function enhanceMessageCopyButtons(root) {
            if (!root || typeof root.querySelectorAll !== 'function') { return; }
            root.querySelectorAll('[data-message-copy-base64]').forEach(function(button) {
                if (button.dataset.copyBound === '1') { return; }
                button.dataset.copyBound = '1';

                button.addEventListener('click', function() {
                    const source = button.getAttribute('data-message-copy-base64') || '';
                    if (!source) { return; }

                    let text = '';
                    try {
                        text = decodeURIComponent(escape(window.atob(source)));
                    } catch (decodeError) {
                        console.error('decode message copy failed', decodeError);
                        return;
                    }

                    copyCodeText(text).then(function() {
                        const resetLabel = \(resetFromDataAttribute) ? (button.getAttribute('data-copy-label') || '') : '';
                        button.textContent = '\(escapedCopiedLabel)';
                        button.classList.add('is-copied');
                        window.setTimeout(function() {
                            if (resetLabel) {
                                button.textContent = resetLabel;
                            }
                            button.classList.remove('is-copied');
                        }, 1600);
                    }).catch(function(error) {
                        console.error('copy message failed', error);
                    });
                });
            });
        }
        """
    }

    private static func escapeJavaScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}
