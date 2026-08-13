import XCTest
@testable import MarkpadCore

/// The ZIP container is hand-written, so it is verified against independent readers:
/// `unzip` for structural integrity and byte-exact round-tripping of content.
final class ZipWriterTests: XCTestCase {
    private func archive(_ files: [(String, Data)]) throws -> Data {
        var writer = ZipWriter()
        for (name, data) in files {
            try writer.addFile(name: name, data: data)
        }
        return try writer.finalize()
    }

    private func unzip(_ data: Data, into directory: URL) throws -> Int32 {
        let archiveURL = directory.appendingPathComponent("archive.zip")
        try data.write(to: archiveURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archiveURL.path, "-d", directory.appendingPathComponent("out").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testCRC32MatchesKnownVector() {
        // The standard CRC-32 of "123456789" is 0xCBF43926.
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipWriter.crc32(Data()), 0)
    }

    func testUnzipVerifiesArchiveIntegrity() throws {
        let data = try archive([
            ("hello.txt", Data("Hello, world".utf8)),
            ("nested/path/file.xml", Data("<a>b</a>".utf8))
        ])
        try Fixtures.withTemporaryDirectory { directory in
            let archiveURL = directory.appendingPathComponent("test.zip")
            try data.write(to: archiveURL)

            // `unzip -t` recomputes every CRC and validates the central directory.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-t", archiveURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "unzip -t rejected the archive")
        }
    }

    func testContentsRoundTripByteForByte() throws {
        let payloads: [(String, Data)] = [
            ("empty.txt", Data()),
            ("small.txt", Data("x".utf8)),
            ("repetitive.txt", Data(String(repeating: "markpad ", count: 5000).utf8)),
            ("unicode.txt", Data("héllo — naïve ✅ 日本語".utf8)),
            ("random.bin", Data((0..<20_000).map { _ in UInt8.random(in: 0...255) }))
        ]
        let data = try archive(payloads)

        try Fixtures.withTemporaryDirectory { directory in
            XCTAssertEqual(try unzip(data, into: directory), 0, "unzip failed")
            for (name, expected) in payloads {
                let url = directory.appendingPathComponent("out").appendingPathComponent(name)
                let actual = try Data(contentsOf: url)
                XCTAssertEqual(actual, expected, "\(name) did not round-trip")
            }
        }
    }

    func testCompressibleDataIsActuallyCompressed() throws {
        let repetitive = Data(String(repeating: "a", count: 100_000).utf8)
        let data = try archive([("big.txt", repetitive)])
        XCTAssertLessThan(data.count, repetitive.count / 10, "deflate should shrink repetitive data")
    }

    func testIncompressibleDataStillRoundTrips() throws {
        // Random bytes can deflate larger than the input; the writer must fall back to storing.
        let random = Data((0..<50_000).map { _ in UInt8.random(in: 0...255) })
        let data = try archive([("noise.bin", random)])
        try Fixtures.withTemporaryDirectory { directory in
            XCTAssertEqual(try unzip(data, into: directory), 0)
            let url = directory.appendingPathComponent("out/noise.bin")
            XCTAssertEqual(try Data(contentsOf: url), random)
        }
    }

    func testOutputIsDeterministic() throws {
        let files = [("a.txt", Data("one".utf8)), ("b.txt", Data("two".utf8))]
        XCTAssertEqual(try archive(files), try archive(files), "timestamps must not vary between runs")
    }
}
