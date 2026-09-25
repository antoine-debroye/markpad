import XCTest
@testable import MarkpadCore

final class EpubImporterTests: XCTestCase {
    /// A 1×1 PNG.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    private static let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    /// Manifest lists chapter 2 before chapter 1; the spine reverses that and puts a
    /// non-linear notes page first.
    private static let package = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="id">urn:uuid:1</dc:identifier>
        <dc:title>The  Book</dc:title>
        <dc:language>en</dc:language>
      </metadata>
      <manifest>
        <item id="c2" href="text/chapter2.xhtml" media-type="application/xhtml+xml"/>
        <item id="c1" href="text/chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
        <item id="pic" href="images/pic.png" media-type="image/png"/>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
      </manifest>
      <spine>
        <itemref idref="notes" linear="no"/>
        <itemref idref="c1"/>
        <itemref idref="c2"/>
      </spine>
    </package>
    """

    /// Chapter 1 uses an HTML entity undeclared in XML, so it goes through the HTML repairer.
    private static let chapter1 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head><title>The Book</title></head>
    <body><section epub:type="chapter"><h2>Chapter One</h2>
    <p>It was a dark&nbsp;night. See <a href="chapter2.xhtml#end">the end</a>
    or <a href="https://example.com/">the site</a>.</p></section></body></html>
    """

    private static let chapter2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title></head>
    <body><p>Untitled chapter text with <em>style</em>.</p>
    <div><img src="../images/pic.png" alt="A picture"/></div>
    <p id="end">The end.</p></body></html>
    """

    private static let notes = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Notes</title></head>
    <body><h2>Notes</h2><ol><li>A note.</li></ol></body></html>
    """

    private func makeBook(
        encryption: String? = nil,
        package: String = EpubImporterTests.package,
        chapter1: String = EpubImporterTests.chapter1
    ) throws -> Data {
        var writer = ZipWriter()
        try writer.addFile(name: "mimetype", data: Data("application/epub+zip".utf8))
        try writer.addFile(name: "META-INF/container.xml", data: Data(Self.container.utf8))
        if let encryption {
            try writer.addFile(name: "META-INF/encryption.xml", data: Data(encryption.utf8))
        }
        try writer.addFile(name: "OEBPS/content.opf", data: Data(package.utf8))
        try writer.addFile(name: "OEBPS/text/chapter2.xhtml", data: Data(Self.chapter2.utf8))
        try writer.addFile(name: "OEBPS/text/chapter1.xhtml", data: Data(chapter1.utf8))
        try writer.addFile(name: "OEBPS/text/notes.xhtml", data: Data(Self.notes.utf8))
        try writer.addFile(name: "OEBPS/images/pic.png", data: Self.png)
        return try writer.finalize()
    }

    private func convert(
        _ book: Data,
        assets: String? = "Book_assets",
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ImportedMarkdown {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Book.epub")
            try book.write(to: url)
            return try EpubImporter().convert(
                url: url, options: .init(assetFolderName: assets), progress: progress, isCancelled: isCancelled)
        }
    }

    func testSpineOrderImagesLinksAndTitle() throws {
        let result = try convert(try makeBook())
        XCTAssertEqual(result.markdown, """
        # The Book

        ## Chapter One

        It was a dark\u{A0}night. See the end or [the site](https://example.com/).

        Untitled chapter text with *style*.

        ![A picture](Book_assets/pic.png)

        The end.

        ## Notes

        1. A note.

        """)
        XCTAssertEqual(result.assets, [.init(name: "pic.png", data: Self.png)])
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testTitleIsNotAddedWhenTheFirstChapterHasOne() throws {
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Opening</h1><p>Text.</p></body></html>
        """
        let result = try convert(try makeBook(chapter1: chapter), assets: nil)
        XCTAssertTrue(result.markdown.hasPrefix("# Opening\n\nText.\n\nUntitled chapter text with *style*.\n\nA picture\n\n"), result.markdown)
        XCTAssertFalse(result.markdown.contains("The Book"))
    }

    func testDRMIsReportedAsProtected() throws {
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/text/chapter1.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        XCTAssertThrowsError(try convert(try makeBook(encryption: encryption))) { error in
            guard case ConversionError.passwordProtected = error else { return XCTFail("\(error)") }
        }
    }

    func testFontObfuscationIsNotProtection() throws {
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/a.otf"/></enc:CipherData>
          </enc:EncryptedData>
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://ns.adobe.com/pdf/enc#RC"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/b.ttf"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let result = try convert(try makeBook(encryption: encryption))
        XCTAssertTrue(result.markdown.contains("## Chapter One"))
    }

    func testProgressReportsChaptersAndCancellationStops() throws {
        let log = ProgressLog()
        _ = try convert(try makeBook(), progress: { log.record($0) })
        let chapters = log.all.filter { $0.phase == .extractingText }
        XCTAssertEqual(chapters.map(\.unit), [1, 2, 3])
        XCTAssertTrue(chapters.allSatisfy { $0.unitKind == .chapter && $0.totalUnits == 3 })
        XCTAssertEqual(log.all.last?.fractionCompleted, 1)

        let cancelLog = ProgressLog()
        let flag = CancelFlag()
        cancelLog.onEvent = { event in
            if event.phase == .extractingText && event.unit == 2 { flag.set() }
        }
        XCTAssertThrowsError(try convert(try makeBook(), progress: { cancelLog.record($0) }, isCancelled: { flag.value })) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(cancelLog.all.filter { $0.phase == .extractingText }.map(\.unit), [1, 2])
    }

    func testDamagedAndEmptyBooks() throws {
        XCTAssertThrowsError(try convert(Data("not a zip".utf8))) { error in
            guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
        }
        var writer = ZipWriter()
        try writer.addFile(name: "mimetype", data: Data("application/epub+zip".utf8))
        XCTAssertThrowsError(try convert(try writer.finalize())) { error in
            guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
        }
        let emptySpine = Self.package.replacingOccurrences(
            of: #"<itemref idref="notes" linear="no"/>\#n    <itemref idref="c1"/>\#n    <itemref idref="c2"/>"#,
            with: "")
        XCTAssertNotEqual(emptySpine, Self.package)
        XCTAssertThrowsError(try convert(try makeBook(package: emptySpine))) { error in
            guard case ConversionError.noTextFound = error else { return XCTFail("\(error)") }
        }
    }

    func testMissingChapterIsLeftOutWithANotice() throws {
        let package = Self.package.replacingOccurrences(of: "text/chapter2.xhtml", with: "text/missing.xhtml")
        let result = try convert(try makeBook(package: package))
        XCTAssertFalse(result.markdown.contains("Untitled chapter"))
        XCTAssertEqual(result.notices, ["“missing.xhtml” could not be read and was left out."])
    }
}

/// A thread-safe flag the cancellation predicate reads.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
