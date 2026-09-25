import Foundation

/// Where a batch writes its Markdown.
public enum BatchOutputLocation: Sendable, Equatable {
    /// Beside each source file.
    case nextToSource
    /// Everything into one folder.
    case folder(URL)
    /// Into one folder, recreating the sub-folders of each dropped folder.
    case mirror(URL)
}

/// What to do when the Markdown a file would produce already exists.
public enum BatchExistingFilePolicy: Sendable, Equatable {
    /// Leave the existing file alone and skip the source. Running a batch twice over the same
    /// folder then converts only what is new.
    case skip
    /// Write under the next free name: `Report 2.md`.
    case keepBoth
}

/// The work a batch will do, decided before any file is converted.
public struct BatchPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public let id: Int
        public let source: URL
        public let input: ConversionInput
        /// The `.md` this item will be written to. Reserved: no other item shares it, and it
        /// did not exist when the plan was made.
        public let output: URL
        /// Folder name, beside `output`, that pictures are written to and linked through.
        public let assetFolderName: String
    }

    public struct Skipped: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// Not a format Markpad converts.
            case unsupported
            /// Already Markdown.
            case alreadyMarkdown
            /// The Markdown it would produce is already there.
            case outputExists(URL)
            /// An Office lock file or similar that is never a real document.
            case systemFile
        }

        public let source: URL
        public let reason: Reason

        public var explanation: String {
            switch reason {
            case .unsupported: return "Not a format Markpad converts"
            case .alreadyMarkdown: return "Already Markdown"
            case .outputExists(let url): return "\(url.lastPathComponent) already exists"
            case .systemFile: return "Temporary or system file"
            }
        }
    }

    public var items: [Item]
    public var skipped: [Skipped]

    public init(items: [Item], skipped: [Skipped] = []) {
        self.items = items
        self.skipped = skipped
    }
}

/// Turns what the user dropped into a `BatchPlan`.
///
/// Every output name is chosen here, in one pass over the sorted inputs, rather than by the
/// workers as they finish: two sources with the same name would otherwise race for
/// `Report.md`, and which one got `Report 2.md` would change from run to run.
public struct BatchPlanner: Sendable {
    public var location: BatchOutputLocation
    public var existingFiles: BatchExistingFilePolicy

    /// Extended attribute set on the pictures folders a batch writes, so a later batch over the
    /// same folder does not convert its own output.
    public static let generatedAttribute = "net.markpad.generated"

    public init(location: BatchOutputLocation = .nextToSource, existingFiles: BatchExistingFilePolicy = .skip) {
        self.location = location
        self.existingFiles = existingFiles
    }

    public func plan(_ dropped: [URL], fileManager: FileManager = .default) -> BatchPlan {
        var skipped: [BatchPlan.Skipped] = []
        var candidates: [(source: URL, input: ConversionInput, relativeFolder: String)] = []
        var seen = Set<String>()

        for (source, relativeFolder) in expand(dropped, fileManager: fileManager) {
            // The same file dropped twice, or reached through a link, is converted once.
            let identity = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(identity).inserted else { continue }

            let name = source.lastPathComponent
            if Self.isSystemFile(name) {
                skipped.append(.init(source: source, reason: .systemFile))
                continue
            }
            guard let input = ConversionInput.detect(for: source) else {
                skipped.append(.init(source: source, reason: .unsupported))
                continue
            }
            if input == .markdown, Self.isMarkdownExtension(source.pathExtension) {
                skipped.append(.init(source: source, reason: .alreadyMarkdown))
                continue
            }
            candidates.append((source, input, relativeFolder))
        }

        // Sorted so the same inputs always produce the same names.
        candidates.sort { $0.source.path.localizedStandardCompare($1.source.path) == .orderedAscending }

        // Sources that would land on the same name in the same folder are told apart by their
        // format — `Report (docx).md`, `Report (pdf).md` — which says more than `Report 2.md`.
        var stemCounts: [String: Int] = [:]
        for candidate in candidates {
            let key = stemKey(directory: outputDirectory(for: candidate.source, relativeFolder: candidate.relativeFolder),
                              stem: candidate.source.deletingPathExtension().lastPathComponent)
            stemCounts[key, default: 0] += 1
        }

        var reserved = Set<String>()
        var items: [BatchPlan.Item] = []
        for candidate in candidates {
            let directory = outputDirectory(for: candidate.source, relativeFolder: candidate.relativeFolder)
            let stem = candidate.source.deletingPathExtension().lastPathComponent
            let clash = (stemCounts[stemKey(directory: directory, stem: stem)] ?? 0) > 1
            let suffix = clash ? " (\(candidate.source.pathExtension.lowercased()))" : ""
            let base = Self.fitting(stem, reserving: suffix.utf8.count) + suffix

            guard let name = reserveName(base: base, in: directory, reserved: &reserved, fileManager: fileManager) else {
                skipped.append(.init(
                    source: candidate.source,
                    reason: .outputExists(directory.appendingPathComponent(base + ".md"))
                ))
                continue
            }
            items.append(.init(
                id: items.count,
                source: candidate.source,
                input: candidate.input,
                output: directory.appendingPathComponent(name + ".md"),
                assetFolderName: name + "_assets"
            ))
        }
        return BatchPlan(items: items, skipped: skipped)
    }

    // MARK: - Expansion

    /// Files to consider, each with the folder path it should be mirrored under.
    func expand(_ dropped: [URL], fileManager: FileManager) -> [(URL, String)] {
        var files: [(URL, String)] = []
        for url in dropped {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            guard isFolder else {
                files.append((url, ""))
                continue
            }
            // Mirrored relative to the dropped folder's parent, so the dropped folder's own
            // name becomes the top level of the copy — whatever volume it came from.
            let rootName = url.lastPathComponent
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            let rootComponents = url.standardizedFileURL.pathComponents.count
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isPackage != true {
                    if Self.isGeneratedAssetsFolder(item, fileManager: fileManager) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                // A link to a folder is not followed: it may lead back up the tree.
                if values?.isSymbolicLink == true {
                    let target = item.resolvingSymlinksInPath()
                    if (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                       (try? target.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true {
                        continue
                    }
                }
                let components = item.standardizedFileURL.pathComponents
                let inner = components.dropFirst(rootComponents).dropLast()
                files.append((item, ([rootName] + inner).joined(separator: "/")))
            }
        }
        return files
    }

    func outputDirectory(for source: URL, relativeFolder: String) -> URL {
        switch location {
        case .nextToSource:
            return source.deletingLastPathComponent()
        case .folder(let folder):
            return folder
        case .mirror(let root):
            return relativeFolder.isEmpty ? root : root.appendingPathComponent(relativeFolder, isDirectory: true)
        }
    }

    // MARK: - Names

    /// The first free name for `base` in `directory`: free on disk for both the `.md` and its
    /// pictures folder, and not already promised to another item. Nil when the policy is to
    /// skip and the plain name is taken.
    private func reserveName(
        base: String,
        in directory: URL,
        reserved: inout Set<String>,
        fileManager: FileManager
    ) -> String? {
        func key(_ name: String) -> String {
            directory.standardizedFileURL.appendingPathComponent(name).path.lowercased()
        }
        func isFree(_ name: String) -> Bool {
            let markdown = name + ".md"
            let assets = name + "_assets"
            return !reserved.contains(key(markdown)) && !reserved.contains(key(assets))
                && !fileManager.fileExists(atPath: directory.appendingPathComponent(markdown).path)
                && !fileManager.fileExists(atPath: directory.appendingPathComponent(assets).path)
        }

        let markdownExists = fileManager.fileExists(atPath: directory.appendingPathComponent(base + ".md").path)
        if markdownExists, existingFiles == .skip { return nil }

        var name = base
        var counter = 2
        while !isFree(name) {
            name = "\(base) \(counter)"
            counter += 1
        }
        reserved.insert(key(name + ".md"))
        reserved.insert(key(name + "_assets"))
        return name
    }

    /// Room left in a 255-byte file name for the stem, after the longest ending a name can get:
    /// ` 999` for a clash and `_assets` for the pictures folder.
    static let maximumStemBytes = 255 - " 999".utf8.count - "_assets".utf8.count

    /// `stem`, shortened at a character boundary so that it and `reserving` more bytes fit.
    static func fitting(_ stem: String, reserving: Int) -> String {
        let limit = maximumStemBytes - reserving
        guard stem.utf8.count > limit else { return stem }
        var result = ""
        for character in stem {
            guard result.utf8.count + String(character).utf8.count <= limit else { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func stemKey(directory: URL, stem: String) -> String {
        directory.standardizedFileURL.path.lowercased() + "\u{0}" + stem.lowercased()
    }

    // MARK: - Filters

    static func isSystemFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return name.hasPrefix("~$") || lower == "thumbs.db" || lower == "desktop.ini" || lower == ".ds_store"
    }

    public static func isMarkdownExtension(_ ext: String) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mdtext"].contains(ext.lowercased())
    }

    /// A pictures folder a previous batch wrote: marked with `generatedAttribute`, or named
    /// `<stem>_assets` beside a `<stem>.md`.
    static func isGeneratedAssetsFolder(_ url: URL, fileManager: FileManager) -> Bool {
        if getxattr(url.path, generatedAttribute, nil, 0, 0, 0) >= 0 { return true }
        let name = url.lastPathComponent
        guard name.hasSuffix("_assets") else { return false }
        let stem = String(name.dropLast("_assets".count))
        let markdown = url.deletingLastPathComponent().appendingPathComponent(stem + ".md")
        return fileManager.fileExists(atPath: markdown.path)
    }
}
