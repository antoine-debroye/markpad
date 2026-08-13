import Compression
import Foundation

/// Minimal ZIP writer for the OPC container of a `.docx`.
///
/// Word needs only stored and deflated entries with no ZIP64 records, so a focused writer
/// keeps the app dependency-free. Timestamps are fixed so the same document always produces
/// the same bytes, which makes golden-file tests meaningful.
struct ZipWriter {
    private struct Entry {
        let name: String
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let method: UInt16
        let localHeaderOffset: UInt32
    }

    private var payload = Data()
    private var entries: [Entry] = []

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endOfDirectorySignature: UInt32 = 0x0605_4b50
    /// 1980-01-01 00:00, the earliest timestamp the format can express.
    private static let dosDate: UInt16 = 0x0021
    private static let dosTime: UInt16 = 0

    enum Failure: Error {
        case entryTooLarge(String)
        case nameNotEncodable(String)
    }

    mutating func addFile(name: String, data: Data) throws {
        guard let nameBytes = name.data(using: .utf8) else { throw Failure.nameNotEncodable(name) }
        guard data.count <= UInt32.max, payload.count <= UInt32.max else {
            throw Failure.entryTooLarge(name)
        }

        let compressed = Self.deflate(data)
        let method: UInt16 = compressed == nil ? 0 : 8
        let body = compressed ?? data
        let entry = Entry(
            name: name,
            crc32: Self.crc32(data),
            compressedSize: UInt32(body.count),
            uncompressedSize: UInt32(data.count),
            method: method,
            localHeaderOffset: UInt32(payload.count)
        )

        var header = Data()
        header.appendLE(Self.localHeaderSignature)
        header.appendLE(UInt16(20))          // version needed to extract
        header.appendLE(UInt16(0))           // general purpose flags
        header.appendLE(entry.method)
        header.appendLE(Self.dosTime)
        header.appendLE(Self.dosDate)
        header.appendLE(entry.crc32)
        header.appendLE(entry.compressedSize)
        header.appendLE(entry.uncompressedSize)
        header.appendLE(UInt16(nameBytes.count))
        header.appendLE(UInt16(0))           // extra field length
        header.append(nameBytes)

        payload.append(header)
        payload.append(body)
        entries.append(entry)
    }

    func finalize() throws -> Data {
        var archive = payload
        let directoryOffset = archive.count

        for entry in entries {
            guard let nameBytes = entry.name.data(using: .utf8) else {
                throw Failure.nameNotEncodable(entry.name)
            }
            var header = Data()
            header.appendLE(Self.centralHeaderSignature)
            header.appendLE(UInt16(20))      // version made by
            header.appendLE(UInt16(20))      // version needed to extract
            header.appendLE(UInt16(0))       // general purpose flags
            header.appendLE(entry.method)
            header.appendLE(Self.dosTime)
            header.appendLE(Self.dosDate)
            header.appendLE(entry.crc32)
            header.appendLE(entry.compressedSize)
            header.appendLE(entry.uncompressedSize)
            header.appendLE(UInt16(nameBytes.count))
            header.appendLE(UInt16(0))       // extra field length
            header.appendLE(UInt16(0))       // comment length
            header.appendLE(UInt16(0))       // disk number start
            header.appendLE(UInt16(0))       // internal attributes
            header.appendLE(UInt32(0))       // external attributes
            header.appendLE(entry.localHeaderOffset)
            header.append(nameBytes)
            archive.append(header)
        }

        let directorySize = archive.count - directoryOffset
        var end = Data()
        end.appendLE(Self.endOfDirectorySignature)
        end.appendLE(UInt16(0))              // this disk number
        end.appendLE(UInt16(0))              // disk with central directory
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt32(directorySize))
        end.appendLE(UInt32(directoryOffset))
        end.appendLE(UInt16(0))              // comment length
        archive.append(end)
        return archive
    }

    // MARK: - Compression

    /// Raw DEFLATE, as ZIP method 8 requires. `COMPRESSION_ZLIB` in Apple's Compression
    /// framework emits raw deflate without the zlib wrapper. Returns nil when the data does
    /// not compress (or is empty), in which case the caller stores it verbatim.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 4096
        var output = Data(count: capacity)

        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0, written < data.count else { return nil }
        output.removeSubrange(written...)
        return output
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
