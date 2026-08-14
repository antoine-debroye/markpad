import AppKit
import WebKit

/// Renders Mermaid diagrams to pictures.
///
/// Mermaid is a JavaScript library, so there is no native path: a hidden web view runs the
/// bundled copy and hands back the SVG it produced along with the size it needs. The library
/// is bundled rather than fetched, so diagrams render offline and a document never causes a
/// network request while you type.
@MainActor
final class MermaidRenderer: NSObject {
    struct Diagram {
        let image: NSImage
        let svg: String
        let size: CGSize
    }

    enum Failure: LocalizedError {
        case resourcesMissing
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .resourcesMissing: return "The Mermaid renderer is missing from the app bundle."
            case .renderFailed(let message): return message
            }
        }
    }

    static let shared = MermaidRenderer()

    private var webView: WKWebView?
    private var isLoaded = false
    private var pendingLoad: [CheckedContinuation<Void, Error>] = []

    /// Cache keyed by diagram source and appearance, so scrolling and re-styling do not
    /// re-run the renderer.
    private var cache: [String: Diagram] = [:]
    private var failed: Set<String> = []
    private var inFlight: Set<String> = []

    /// Called when a diagram becomes available and the text needs redrawing.
    var onRender: (() -> Void)?

    private func key(_ source: String, dark: Bool) -> String {
        "\(dark ? "dark" : "light")\u{1}\(source)"
    }

    func diagram(for source: String, dark: Bool) -> Diagram? {
        cache[key(source, dark: dark)]
    }

    func hasFailed(_ source: String, dark: Bool) -> Bool {
        failed.contains(key(source, dark: dark))
    }

    /// Renders run one at a time: they share a single web view, and letting two overlap
    /// means the second replaces the page contents before the first is captured.
    private var renderChain: Task<Void, Never> = Task {}

    /// Starts rendering unless the diagram is already available or in progress.
    func prepare(_ source: String, dark: Bool) {
        let cacheKey = key(source, dark: dark)
        guard cache[cacheKey] == nil, !failed.contains(cacheKey), !inFlight.contains(cacheKey) else { return }
        inFlight.insert(cacheKey)

        let previous = renderChain
        renderChain = Task { @MainActor in
            await previous.value
            defer { inFlight.remove(cacheKey) }
            do {
                cache[cacheKey] = try await render(source, dark: dark)
            } catch {
                failed.insert(cacheKey)
            }
            onRender?()
        }
    }

    /// Renders on demand, used by export where the result is needed straight away.
    func diagramRenderingIfNeeded(_ source: String, dark: Bool) async -> Diagram? {
        let cacheKey = key(source, dark: dark)
        if let cached = cache[cacheKey] { return cached }
        guard !failed.contains(cacheKey) else { return nil }
        do {
            let diagram = try await render(source, dark: dark)
            cache[cacheKey] = diagram
            return diagram
        } catch {
            failed.insert(cacheKey)
            return nil
        }
    }

    func retain(sources: [String], dark: Bool) {
        let keys = Set(sources.map { key($0, dark: dark) })
        cache = cache.filter { keys.contains($0.key) }
        failed = failed.filter { keys.contains($0) }
    }

    // MARK: Rendering

    private func render(_ source: String, dark: Bool) async throws -> Diagram {
        let webView = try await loadedWebView()

        let arguments: [String: Any] = ["source": source, "dark": dark]
        let result = try await webView.callAsyncJavaScript(
            "return await mermaidRender(source, dark);",
            arguments: arguments,
            contentWorld: .page
        )

        guard let payload = result as? [String: Any],
              let svg = payload["svg"] as? String,
              let width = payload["width"] as? Double,
              let height = payload["height"] as? Double,
              width > 0, height > 0 else {
            throw Failure.renderFailed("The diagram could not be drawn.")
        }

        let size = CGSize(width: width, height: height)
        webView.frame = NSRect(origin: .zero, size: size)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(origin: .zero, size: size)
        // Render at the display's scale so the picture stays sharp.
        configuration.snapshotWidth = NSNumber(value: Double(size.width))

        let image = try await webView.takeSnapshot(configuration: configuration)
        return Diagram(image: image, svg: svg, size: size)
    }

    private func loadedWebView() async throws -> WKWebView {
        if let webView, isLoaded { return webView }

        let webView = self.webView ?? makeWebView()
        self.webView = webView

        guard let host = Bundle.main.url(forResource: "mermaid-host", withExtension: "html", subdirectory: "Mermaid")
                ?? Bundle.main.url(forResource: "mermaid-host", withExtension: "html") else {
            throw Failure.resourcesMissing
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingLoad.append(continuation)
            if pendingLoad.count == 1 {
                webView.loadFileURL(host, allowingReadAccessTo: host.deletingLastPathComponent())
            }
        }
        isLoaded = true
        return webView
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }
}

extension MermaidRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let waiting = pendingLoad
        pendingLoad.removeAll()
        waiting.forEach { $0.resume() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let waiting = pendingLoad
        pendingLoad.removeAll()
        waiting.forEach { $0.resume(throwing: error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let waiting = pendingLoad
        pendingLoad.removeAll()
        waiting.forEach { $0.resume(throwing: error) }
    }
}
