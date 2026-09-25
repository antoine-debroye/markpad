import Compression
import Foundation

/// Reads the entries of a ZIP archive — the container behind `.docx`, `.pptx`, `.xlsx` and
/// `.epub`.
///
/// Scoped to what those formats use: stored and deflated entries, read through the central
/// directory. Office and EPUB writers do not produce multi-disk or ZIP64 archives for ordinary
/// documents, so those are rejected rather than half-supported. Everything is bounds-checked,
/// because the input is an arbitrary file the user picked and may be truncated or hostile.
struct ZipReader {
    struct Entry: Sendable, Equatable {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    enum Failure: Error, Equatable {
        /// Not a ZIP archive, or its directory is damaged.
        case notAnArchive
        /// An Office document encrypted with a password. Word wraps those in an OLE compound
        /// file rather than a ZIP, so they are recognised by that container's signature.
        case passwordProtected
        /// An entry whose data is encrypted, split across disks, or stored with a method other
        /// than stored or deflate.
        case unsupportedEntry(String)
        /// Expanding an entry would exceed the size limit.
        case tooLarge(String)
        /// An entry's data did not match its checksum.
        case corrupt(String)
    }

    /// Largest expanded size accepted for one entry. Generous for text parts, and a guard
    /// against a small archive that expands to gigabytes.
    static let maximumEntrySize = 512 * 1024 * 1024

    /// The OLE2 compound-file signature. An encrypted `.docx`/`.xlsx`/`.pptx` is one of these.
    static let compoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    let entries: [Entry]
    private let data: Data
    private let byName: [String: Int]
    /// Bytes this archive may still expand to, shared by every copy of the reader. Each entry
    /// is small enough alone; a document referencing hundreds of them is not.
    private let budget: ExpansionBudget

    final class ExpansionBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int

        init(_ bytes: Int) { remaining = bytes }

        func spend(_ bytes: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard bytes <= remaining else { return false }
            remaining -= bytes
            return true
        }
    }

    init(url: URL) throws {
        // Mapped rather than read, so a large archive is paged in only where entries are read.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data)
    }

    init(data: Data, expansionBudget: Int = ImportLimits.archiveExpansionBudget) throws {
        budget = ExpansionBudget(expansionBudget)
        // A Data slice can have a non-zero start index; normalise so offsets are simple.
        let data = data.startIndex == 0 ? data : Data(data)
        if data.count >= 8, Array(data.prefix(8)) == Self.compoundFileSignature {
            throw Failure.passwordProtected
        }
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
        var byName: [String: Int] = [:]
        for (index, entry) in entries.enumerated() where byName[entry.name] == nil {
            byName[entry.name] = index
        }
        self.byName = byName
    }

    func entry(named name: String) -> Entry? {
        byName[Self.normalise(name)].map { entries[$0] }
    }

    func contains(_ name: String) -> Bool { entry(named: name) != nil }

    /// The expanded contents of `name`, or nil when the archive has no such entry.
    func data(for name: String) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        return try data(for: entry)
    }

    /// The expanded contents of `name` as UTF-8 text.
    func text(for name: String) throws -> String? {
        guard let data = try data(for: name) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func data(for entry: Entry) throws -> Data {
        if entry.flags & 0x1 != 0 { throw Failure.unsupportedEntry(entry.name) }
        guard entry.uncompressedSize <= Self.maximumEntrySize else { throw Failure.tooLarge(entry.name) }
        // Charged before anything is allocated: the declared size sizes the buffer.
        guard budget.spend(entry.uncompressedSize) else { throw Failure.tooLarge(entry.name) }

        // The local header repeats the name and may carry a different extra field, so the data
        // offset has to be read from it rather than derived from the central directory.
        let local = entry.localHeaderOffset
        guard local >= 0, local + 30 <= data.count, data.readLE32(at: local) == 0x0403_4b50 else {
            throw Failure.notAnArchive
        }
        let nameLength = Int(data.readLE16(at: local + 26))
        let extraLength = Int(data.readLE16(at: local + 28))
        let start = local + 30 + nameLength + extraLength
        guard start <= data.count, entry.compressedSize <= data.count - start else {
            throw Failure.notAnArchive
        }
        let body = data.subdata(in: start..<(start + entry.compressedSize))

        let expanded: Data
        switch entry.method {
        case 0:
            expanded = body
        case 8:
            expanded = try Self.inflate(body, expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw Failure.unsupportedEntry(entry.name)
        }
        guard expanded.count == entry.uncompressedSize, ZipWriter.crc32(expanded) == entry.crc32 else {
            throw Failure.corrupt(entry.name)
        }
        return expanded
    }

    /// Resolves `target` relative to the part at `base`, as OPC relationships and EPUB manifests
    /// do. Returns nil for a reference that escapes the archive root or points elsewhere.
    static func resolve(_ target: String, relativeTo base: String) -> String? {
        let decoded = target.removingPercentEncoding ?? target
        if decoded.contains("://") || decoded.hasPrefix("mailto:") { return nil }
        var components: [String]
        if decoded.hasPrefix("/") {
            components = []
        } else {
            components = base.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            components.removeLast()   // the base part's own file name
        }
        let path = decoded.split(separator: "#", maxSplits: 1).first.map(String.init) ?? decoded
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        let joined = components.filter { !$0.isEmpty }.joined(separator: "/")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Parsing

    private static func normalise(_ name: String) -> String {
        name.hasPrefix("/") ? String(name.dropFirst()) : name
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        // The end-of-central-directory record sits in the last 22 bytes plus a comment of up
        // to 64 KB, so it is found by scanning backwards.
        guard data.count >= 22 else { throw Failure.notAnArchive }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var eocd: Int?
        var position = data.count - 22
        while position >= lowest {
            if data.readLE32(at: position) == 0x0605_4b50 { eocd = position; break }
            position -= 1
        }
        guard let end = eocd else { throw Failure.notAnArchive }

        let diskNumber = data.readLE16(at: end + 4)
        let directoryDisk = data.readLE16(at: end + 6)
        let count = Int(data.readLE16(at: end + 10))
        let directorySize = Int(data.readLE32(at: end + 12))
        let directoryOffset = Int(data.readLE32(at: end + 16))
        guard diskNumber == 0, directoryDisk == 0 else { throw Failure.unsupportedEntry("multi-disk archive") }
        if directoryOffset == 0xFFFF_FFFF || count == 0xFFFF {
            throw Failure.unsupportedEntry("ZIP64 archive")
        }
        guard directoryOffset <= end, directorySize <= end - directoryOffset else {
            throw Failure.notAnArchive
        }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= data.count, data.readLE32(at: cursor) == 0x0201_4b50 else {
                throw Failure.notAnArchive
            }
            let flags = data.readLE16(at: cursor + 8)
            let method = data.readLE16(at: cursor + 10)
            let crc = data.readLE32(at: cursor + 16)
            let compressed = data.readLE32(at: cursor + 20)
            let uncompressed = data.readLE32(at: cursor + 24)
            let nameLength = Int(data.readLE16(at: cursor + 28))
            let extraLength = Int(data.readLE16(at: cursor + 30))
            let commentLength = Int(data.readLE16(at: cursor + 32))
            let localOffset = data.readLE32(at: cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw Failure.notAnArchive }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw Failure.unsupportedEntry("ZIP64 archive")
            }

            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            // Bit 11 marks UTF-8 names; older writers use CP437, which agrees with UTF-8 for
            // the ASCII names every OOXML and EPUB part uses.
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            entries.append(Entry(
                name: normalise(name.replacingOccurrences(of: "\\", with: "/")),
                method: method,
                flags: flags,
                crc32: crc,
                compressedSize: Int(compressed),
                uncompressedSize: Int(uncompressed),
                localHeaderOffset: Int(localOffset)
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Raw DEFLATE, the counterpart of `ZipWriter.deflate`. The declared size is trusted only
    /// as an upper bound for the buffer; the checksum afterwards confirms the result.
    private static func inflate(_ body: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return body.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, expectedSize,
                    sourceBase, body.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw Failure.corrupt(name) }
        return output
    }
}

extension Data {
    /// Little-endian reads for binary container formats. Callers bounds-check first.
    func readLE16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func readLE32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[startIndex + offset + index]) << (8 * index)
        }
        return value
    }
}
