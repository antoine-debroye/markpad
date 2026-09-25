import Foundation
import XCTest
@testable import MarkpadCore

final class ZipReaderTests: XCTestCase {
    func testReadsArchivesFromOurWriter() throws {
        var writer = ZipWriter()
        let text = String(repeating: "Compressible text. ", count: 200)
        try writer.addFile(name: "word/document.xml", data: Data(text.utf8))
        try writer.addFile(name: "media/raw.bin", data: Data([0x01, 0x02, 0x03]))   // stored: too small to deflate
        try writer.addFile(name: "empty.txt", data: Data())
        let reader = try ZipReader(data: try writer.finalize())

        XCTAssertEqual(reader.entries.map(\.name), ["word/document.xml", "media/raw.bin", "empty.txt"])
        XCTAssertEqual(reader.entry(named: "word/document.xml")?.method, 8)
        XCTAssertEqual(try reader.text(for: "word/document.xml"), text)
        XCTAssertEqual(try reader.data(for: "/media/raw.bin"), Data([0x01, 0x02, 0x03]), "leading slash tolerated")
        XCTAssertEqual(try reader.data(for: "empty.txt"), Data())
        XCTAssertNil(try reader.data(for: "missing.xml"))
    }

    /// An archive written by an independent implementation, with directories and extra fields.
    func testReadsArchivesFromSystemZip() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("src/sub", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let body = String(repeating: "zip me please ", count: 500)
            try body.write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "é ünïcode".write(to: source.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

            let archive = directory.appendingPathComponent("out.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = directory
            process.arguments = ["-q", "-r", archive.path, "src"]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let reader = try ZipReader(url: archive)
            XCTAssertTrue(reader.entries.contains { $0.name == "src/sub/" && $0.isDirectory })
            XCTAssertEqual(try reader.text(for: "src/sub/a.txt"), body)
            XCTAssertEqual(try reader.text(for: "src/sub/b.txt"), "é ünïcode")
        }
    }

    func testRejectsNonArchives() {
        XCTAssertThrowsError(try ZipReader(data: Data("just some text, not a zip".utf8))) { error in
            XCTAssertEqual(error as? ZipReader.Failure, .notAnArchive)
        }
        XCTAssertThrowsError(try ZipReader(data: Data())) { error in
            XCTAssertEqual(error as? ZipReader.Failure, .notAnArchive)
        }
    }

    func testRecognisesPasswordProtectedOfficeFiles() {
        var data = Data(ZipReader.compoundFileSignature)
        data.append(Data(count: 512))
        XCTAssertThrowsError(try ZipReader(data: data)) { error in
            XCTAssertEqual(error as? ZipReader.Failure, .passwordProtected)
        }
    }

    func testDetectsCorruptedEntryData() throws {
        var writer = ZipWriter()
        try writer.addFile(name: "a.txt", data: Data(String(repeating: "abcdef", count: 100).utf8))
        var archive = try writer.finalize()
        // Flip a byte inside the compressed body (after the 30-byte header and 5-byte name).
        archive[40] ^= 0xFF
        let reader = try ZipReader(data: archive)
        XCTAssertThrowsError(try reader.data(for: "a.txt")) { error in
            XCTAssertEqual(error as? ZipReader.Failure, .corrupt("a.txt"))
        }
    }

    func testTruncatedArchiveIsRejected() throws {
        var writer = ZipWriter()
        try writer.addFile(name: "a.txt", data: Data("hello".utf8))
        let archive = try writer.finalize()
        XCTAssertThrowsError(try ZipReader(data: archive.prefix(archive.count - 10)))
    }

    func testOversizedDeclarationIsRefusedBeforeAllocating() throws {
        var writer = ZipWriter()
        try writer.addFile(name: "bomb.txt", data: Data("x".utf8))
        var archive = try writer.finalize()
        // Rewrite the central directory's uncompressed size to 4 GB - 2.
        let central = archive.count - 22 - (46 + "bomb.txt".utf8.count)
        let huge: [UInt8] = [0xFE, 0xFF, 0xFF, 0xFF]
        archive.replaceSubrange((central + 24)..<(central + 28), with: huge)
        let reader = try ZipReader(data: archive)
        XCTAssertThrowsError(try reader.data(for: "bomb.txt")) { error in
            XCTAssertEqual(error as? ZipReader.Failure, .tooLarge("bomb.txt"))
        }
    }

    func testResolvesRelationshipTargets() {
        XCTAssertEqual(ZipReader.resolve("media/image1.png", relativeTo: "word/document.xml"), "word/media/image1.png")
        XCTAssertEqual(ZipReader.resolve("../media/image1.png", relativeTo: "ppt/slides/slide1.xml"), "ppt/media/image1.png")
        XCTAssertEqual(ZipReader.resolve("/xl/worksheets/sheet1.xml", relativeTo: "xl/workbook.xml"), "xl/worksheets/sheet1.xml")
        XCTAssertEqual(ZipReader.resolve("chapter%201.xhtml#p3", relativeTo: "OEBPS/content.opf"), "OEBPS/chapter 1.xhtml")
        XCTAssertNil(ZipReader.resolve("../../../etc/passwd", relativeTo: "word/document.xml"), "cannot escape the archive")
        XCTAssertNil(ZipReader.resolve("https://example.com/x.png", relativeTo: "word/document.xml"))
    }
}
