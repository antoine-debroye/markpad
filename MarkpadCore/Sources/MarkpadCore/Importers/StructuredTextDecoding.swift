import Foundation

/// Turns the bytes of a plain-text data file (CSV, TSV, JSON, XML) into a string.
///
/// These files carry no reliable encoding label, so the order is: a byte-order mark wins, then
/// UTF-8 if the bytes are valid UTF-8, then a caller-supplied hint (an XML declaration), and
/// finally Windows-1252 — the encoding Excel on Windows still writes CSV in, and one that
/// decodes every byte, so a file is never rejected for its encoding alone.
enum StructuredTextDecoding {
    struct Decoded {
        var text: String
        /// True when a byte-order mark named the encoding.
        var hadByteOrderMark: Bool
    }

    static func decode(_ data: Data, fallbackEncoding: String.Encoding? = nil) -> Decoded? {
        let bytes = [UInt8](data.prefix(4))
        // UTF-32 is checked before UTF-16: FF FE 00 00 starts with the UTF-16 LE mark.
        let marks: [([UInt8], String.Encoding)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
        ]
        for (mark, encoding) in marks where bytes.starts(with: mark) {
            let body = data.dropFirst(mark.count)
            if let text = String(data: body, encoding: encoding) {
                return Decoded(text: text, hadByteOrderMark: true)
            }
            return nil
        }
        if let text = String(data: data, encoding: .utf8) {
            return Decoded(text: text, hadByteOrderMark: false)
        }
        // UTF-16 without a mark: text of mostly ASCII has a zero in every other byte.
        if data.count >= 2, data.count % 2 == 0 {
            let sample = [UInt8](data.prefix(512))
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let half = sample.count / 2
            if evenZeros * 10 > half * 9, oddZeros == 0, let text = String(data: data, encoding: .utf16BigEndian) {
                return Decoded(text: text, hadByteOrderMark: false)
            }
            if oddZeros * 10 > half * 9, evenZeros == 0, let text = String(data: data, encoding: .utf16LittleEndian) {
                return Decoded(text: text, hadByteOrderMark: false)
            }
        }
        if let fallbackEncoding, let text = String(data: data, encoding: fallbackEncoding) {
            return Decoded(text: text, hadByteOrderMark: false)
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return Decoded(text: text, hadByteOrderMark: false)
        }
        return String(data: data, encoding: .isoLatin1).map { Decoded(text: $0, hadByteOrderMark: false) }
    }
}
