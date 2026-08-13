import AppKit
import MarkpadCore

/// Loads and caches the images a document references.
///
/// Loading happens off the main thread and the result is cached by URL and modification
/// date, so scrolling a document full of pictures does not re-read them from disk.
final class ImageStore {
    struct Entry {
        let image: NSImage
        /// Size the image should occupy, already fitted to the available width.
        let displaySize: CGSize
    }

    /// Tallest an image may be drawn, so one picture cannot fill the whole window.
    private static let maximumHeight: CGFloat = 420

    private var cache: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var inFlight: Set<String> = []
    /// Called when an image finishes loading and the text needs redrawing.
    var onLoad: (() -> Void)?

    var documentDirectory: URL?

    /// The image for a Markdown source, or nil while it loads or if it cannot be read.
    func entry(for source: String, availableWidth: CGFloat) -> Entry? {
        guard let key = resolve(source)?.absoluteString else { return nil }
        guard let image = cache[key] else { return nil }

        var size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let widthLimit = max(availableWidth, 80)
        if size.width > widthLimit {
            size = CGSize(width: widthLimit, height: size.height * widthLimit / size.width)
        }
        if size.height > Self.maximumHeight {
            size = CGSize(width: size.width * Self.maximumHeight / size.height, height: Self.maximumHeight)
        }
        return Entry(image: image, displaySize: size)
    }

    /// True when the source resolves to a file that could not be decoded.
    func hasFailed(_ source: String) -> Bool {
        guard let key = resolve(source)?.absoluteString else { return true }
        return failed.contains(key)
    }

    /// Starts loading if the image is not already available.
    func prepare(_ source: String) {
        guard let url = resolve(source) else { return }
        let key = url.absoluteString
        guard cache[key] == nil, !failed.contains(key), !inFlight.contains(key) else { return }
        inFlight.insert(key)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = NSImage(contentsOf: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(key)
                if let image, image.size.width > 0 {
                    self.cache[key] = image
                } else {
                    self.failed.insert(key)
                }
                self.onLoad?()
            }
        }
    }

    /// Drops cached images no longer referenced by the document.
    func retain(sources: [String]) {
        let keys = Set(sources.compactMap { resolve($0)?.absoluteString })
        cache = cache.filter { keys.contains($0.key) }
        failed = failed.filter { keys.contains($0) }
    }

    /// Resolves a Markdown image source against the document's folder. Remote images are
    /// not fetched: an editor should not make network requests while you type.
    private func resolve(_ source: String) -> URL? {
        guard !source.isEmpty else { return nil }
        let decoded = source.removingPercentEncoding ?? source

        if let url = URL(string: source), let scheme = url.scheme {
            return scheme == "file" ? url.standardizedFileURL : nil
        }
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded).standardizedFileURL
        }
        guard let directory = documentDirectory else { return nil }
        return URL(fileURLWithPath: decoded, relativeTo: directory).standardizedFileURL
    }
}
