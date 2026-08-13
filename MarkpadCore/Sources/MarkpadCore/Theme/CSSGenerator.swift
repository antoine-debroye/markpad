import Foundation

/// Builds the stylesheet for exported HTML and Quick Look previews from theme tokens.
///
/// Colours are emitted as custom properties twice: once for light and once inside a
/// `prefers-color-scheme: dark` block, so a single file adapts to the viewer's appearance.
public enum CSSGenerator {
    public static func stylesheet(theme: MarkdownTheme) -> String {
        """
        :root {
        \(variables(for: theme.light))
          --mp-font-body: \(theme.bodyFontFamily);
          --mp-font-mono: \(theme.monospaceFontFamily);
          --mp-font-size: \(format(theme.baseFontSize))px;
          --mp-line-height: \(format(theme.lineHeight));
          --mp-content-width: \(format(theme.contentWidth))px;
          color-scheme: light dark;
        }
        @media (prefers-color-scheme: dark) {
          :root {
        \(variables(for: theme.dark))
          }
        }
        * { box-sizing: border-box; }
        html { -webkit-text-size-adjust: 100%; }
        body {
          margin: 0;
          background: var(--mp-background);
          color: var(--mp-text);
          font-family: var(--mp-font-body);
          font-size: var(--mp-font-size);
          line-height: var(--mp-line-height);
          -webkit-font-smoothing: antialiased;
        }
        .markpad {
          max-width: var(--mp-content-width);
          margin: 0 auto;
          padding: 48px 32px 96px;
        }
        .markpad > *:first-child { margin-top: 0; }
        h1, h2, h3, h4, h5, h6 {
          color: var(--mp-heading);
          font-weight: 650;
          line-height: 1.25;
          margin: 1.8em 0 0.6em;
          letter-spacing: -0.011em;
        }
        \(headingSizes(theme: theme))
        h1 { letter-spacing: -0.021em; }
        p { margin: 0 0 1.05em; }
        a { color: var(--mp-link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        strong { font-weight: 650; }
        del { color: var(--mp-secondary-text); }
        ul, ol { margin: 0 0 1.05em; padding-left: 1.6em; }
        li { margin: 0.25em 0; }
        li > ul, li > ol { margin: 0.25em 0; }
        ul.task-list { list-style: none; padding-left: 0.2em; }
        .task-item { display: flex; align-items: baseline; gap: 0.55em; }
        .task-item input { margin: 0; transform: translateY(1px); }
        blockquote {
          margin: 1.2em 0;
          padding: 0.1em 0 0.1em 1.1em;
          border-left: 3px solid var(--mp-quote-bar);
          color: var(--mp-quote-text);
        }
        blockquote > *:last-child { margin-bottom: 0; }
        code {
          font-family: var(--mp-font-mono);
          font-size: 0.88em;
          background: var(--mp-code-background);
          color: var(--mp-code-text);
          padding: 0.15em 0.36em;
          border-radius: 4px;
        }
        pre {
          background: var(--mp-code-background);
          border-radius: 8px;
          padding: 14px 16px;
          overflow-x: auto;
          margin: 1.2em 0;
        }
        pre code {
          background: none;
          color: var(--mp-text);
          padding: 0;
          font-size: 0.86em;
          line-height: 1.5;
        }
        hr {
          border: none;
          border-top: 1px solid var(--mp-rule);
          margin: 2.2em 0;
        }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        table {
          border-collapse: collapse;
          width: 100%;
          margin: 1.3em 0;
          font-size: 0.95em;
          display: block;
          overflow-x: auto;
        }
        th, td {
          border: 1px solid var(--mp-table-border);
          padding: 7px 11px;
          text-align: left;
        }
        thead th { background: var(--mp-table-header-background); font-weight: 620; }
        """
    }

    private static func variables(for palette: MarkdownTheme.Palette) -> String {
        let entries: [(String, String)] = [
            ("--mp-background", palette.background),
            ("--mp-text", palette.text),
            ("--mp-secondary-text", palette.secondaryText),
            ("--mp-heading", palette.heading),
            ("--mp-link", palette.link),
            ("--mp-code-text", palette.codeText),
            ("--mp-code-background", palette.codeBackground),
            ("--mp-quote-bar", palette.quoteBar),
            ("--mp-quote-text", palette.quoteText),
            ("--mp-rule", palette.rule),
            ("--mp-table-border", palette.tableBorder),
            ("--mp-table-header-background", palette.tableHeaderBackground)
        ]
        return entries.map { "  \($0.0): \($0.1);" }.joined(separator: "\n")
    }

    private static func headingSizes(theme: MarkdownTheme) -> String {
        (1...6).map { level in
            let ratio = theme.fontSize(forHeadingLevel: level) / theme.baseFontSize
            return "h\(level) { font-size: \(format(ratio))em; }"
        }.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }
}
