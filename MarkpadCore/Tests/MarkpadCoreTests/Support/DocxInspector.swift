import Foundation
import XCTest

/// Unpacks a generated `.docx` and checks the structural invariants Word relies on.
///
/// Word reports a vague "unreadable content" error for any of these violations, so they are
/// asserted directly rather than inferred from a failed open.
///
/// Extraction deliberately uses `/usr/bin/unzip` rather than the library that wrote the
/// archive: an independent reader catches container bugs that a round-trip through the same
/// implementation would hide.
struct DocxInspector {
    let parts: [String: Data]

    init(data: Data) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markpad-docx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent("document.docx")
        try data.write(to: archiveURL)

        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        let status = try Self.run("/usr/bin/unzip", ["-q", "-o", archiveURL.path, "-d", unpacked.path])
        guard status == 0 else {
            throw NSError(domain: "DocxInspector", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "unzip could not read the generated .docx (status \(status))"
            ])
        }

        var parts: [String: Data] = [:]
        // Resolve symlinks on both sides: /var/folders and /private/var/folders name the
        // same directory, and only one of the two comes back from the enumerator.
        let root = unpacked.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let absolute = url.resolvingSymlinksInPath().path
            guard absolute.hasPrefix(root + "/") else { continue }
            parts[String(absolute.dropFirst(root.count + 1))] = try Data(contentsOf: url)
        }
        guard !parts.isEmpty else {
            throw NSError(domain: "DocxInspector", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "no parts were extracted from the .docx"
            ])
        }
        self.parts = parts
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func xml(_ path: String) throws -> XMLDocument {
        guard let data = parts[path] else {
            throw XCTSkip("part \(path) is missing")
        }
        return try XMLDocument(data: data, options: [])
    }

    func text(_ path: String) -> String {
        parts[path].flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Concatenated visible text of the document body.
    func documentText() -> String {
        let xml = text("word/document.xml")
        var out = ""
        var remainder = Substring(xml)
        while let open = remainder.range(of: "<w:t"),
              let contentStart = remainder[open.lowerBound...].range(of: ">"),
              let close = remainder[contentStart.upperBound...].range(of: "</w:t>") {
            out += remainder[contentStart.upperBound..<close.lowerBound]
            remainder = remainder[close.upperBound...]
        }
        return out
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Every part parses as XML, every referenced relationship resolves, every part
    /// extension is declared in `[Content_Types].xml`, and drawing ids are unique.
    func validate(file: StaticString = #filePath, line: UInt = #line) throws {
        for (path, data) in parts where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
            XCTAssertNoThrow(
                try XMLDocument(data: data, options: []),
                "\(path) is not well-formed XML",
                file: file, line: line
            )
        }

        for required in ["[Content_Types].xml", "_rels/.rels", "word/document.xml",
                         "word/_rels/document.xml.rels", "word/styles.xml", "word/numbering.xml"] {
            XCTAssertNotNil(parts[required], "missing required part \(required)", file: file, line: line)
        }

        // Relationship graph: every r:id / r:embed used in the document must be declared.
        let relationshipsXML = text("word/_rels/document.xml.rels")
        let declared = Set(matches(in: relationshipsXML, pattern: #"Id="([^"]+)""#))
        let used = Set(matches(in: text("word/document.xml"), pattern: #"r:(?:id|embed)="([^"]+)""#))
        let dangling = used.subtracting(declared)
        XCTAssertTrue(dangling.isEmpty, "document references undeclared relationships: \(dangling)",
                      file: file, line: line)

        // Internal relationship targets must exist as parts; external ones must say so.
        let relationshipLines = relationshipsXML.components(separatedBy: "<Relationship ")
        for entry in relationshipLines.dropFirst() {
            guard let target = firstMatch(in: entry, pattern: #"Target="([^"]+)""#) else { continue }
            if entry.contains("TargetMode=\"External\"") { continue }
            let resolved = "word/" + target
            XCTAssertNotNil(parts[resolved], "relationship target \(resolved) has no part",
                            file: file, line: line)
        }

        // Hyperlinks must be external or Word refuses to open the package.
        for entry in relationshipLines.dropFirst() where entry.contains("/hyperlink") {
            XCTAssertTrue(entry.contains("TargetMode=\"External\""),
                          "hyperlink relationship must be external: \(entry.prefix(120))",
                          file: file, line: line)
        }

        // Content types must cover every extension present in the package.
        let contentTypes = text("[Content_Types].xml")
        for path in parts.keys {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard !ext.isEmpty, ext != "xml", ext != "rels" else { continue }
            XCTAssertTrue(contentTypes.contains("Extension=\"\(ext)\""),
                          "[Content_Types].xml does not declare .\(ext)", file: file, line: line)
        }

        // Drawing ids must be document-wide unique.
        let drawingIDs = matches(in: text("word/document.xml"), pattern: #"<wp:docPr id="(\d+)""#)
        XCTAssertEqual(Set(drawingIDs).count, drawingIDs.count, "duplicate wp:docPr ids", file: file, line: line)

        // Every numId referenced must exist in numbering.xml.
        let usedNumbers = Set(matches(in: text("word/document.xml"), pattern: #"<w:numId w:val="(\d+)""#))
        let declaredNumbers = Set(matches(in: text("word/numbering.xml"), pattern: #"<w:num w:numId="(\d+)""#))
        XCTAssertTrue(usedNumbers.subtracting(declaredNumbers).isEmpty,
                      "document uses numbering ids that numbering.xml doesn't declare: " +
                      "\(usedNumbers.subtracting(declaredNumbers))", file: file, line: line)

        // Every table cell needs a paragraph.
        let cells = text("word/document.xml").components(separatedBy: "<w:tc>").dropFirst()
        for cell in cells {
            let body = cell.components(separatedBy: "</w:tc>").first ?? ""
            XCTAssertTrue(body.contains("<w:p>") || body.contains("<w:p/>"),
                          "table cell without a paragraph", file: file, line: line)
        }
    }

    private func matches(in string: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            Range(match.range(at: 1), in: string).map { String(string[$0]) }
        }
    }

    private func firstMatch(in string: String, pattern: String) -> String? {
        matches(in: string, pattern: pattern).first
    }
}
