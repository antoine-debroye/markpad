import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MarkpadCore

/// How files are classified and routed to an importer.
final class ConversionRoutingTests: XCTestCase {
    func testEveryExtensionIsDetected() {
        let expectations: [String: ConversionInput] = [
            "md": .markdown, "markdown": .markdown, "txt": .markdown,
            "pdf": .pdf,
            "png": .image, "JPG": .image, "heic": .image, "webp": .image,
            "docx": .wordDocument, "docm": .wordDocument, "dotx": .wordDocument,
            "doc": .richText, "rtf": .richText, "rtfd": .richText, "odt": .richText,
            "html": .webPage, "htm": .webPage, "xhtml": .webPage, "webarchive": .webPage,
            "pptx": .presentation, "pptm": .presentation, "potx": .presentation,
            "xlsx": .spreadsheet, "xlsm": .spreadsheet, "xltx": .spreadsheet,
            "epub": .ebook,
            "csv": .delimitedText, "tsv": .delimitedText,
            "json": .json, "xml": .xml,
            "m4a": .audio, "mp3": .audio, "wav": .audio, "aiff": .audio, "flac": .audio,
        ]
        for (ext, kind) in expectations {
            XCTAssertEqual(ConversionInput.detect(for: URL(fileURLWithPath: "/tmp/file.\(ext)")), kind, ext)
        }
    }

    func testTypesFoundOnlyThroughTheTypeSystem() {
        // Not in the extension table, but the system knows them.
        XCTAssertEqual(ConversionInput.detect(for: URL(fileURLWithPath: "/tmp/a.jpe")), .image)
        XCTAssertEqual(ConversionInput.detect(for: URL(fileURLWithPath: "/tmp/a.aifc")), .audio)
        XCTAssertNil(ConversionInput.detect(for: URL(fileURLWithPath: "/tmp/a.mid")), "MIDI has no speech")
        XCTAssertNil(ConversionInput.detect(for: URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertNil(ConversionInput.detect(for: URL(fileURLWithPath: "/tmp/a.xls")), "legacy Excel is not supported")
        XCTAssertNil(ConversionInput.detect(for: URL(fileURLWithPath: "/tmp/noextension")))
    }

    func testOpenPanelTypesCoverEveryKind() {
        let types = ConversionInput.importableContentTypes
        XCTAssertTrue(types.contains(.rtfd), "rtfd has no extension mapping, so it is added by constant")
        XCTAssertFalse(types.contains { $0.isDynamic })
        for ext in ["docx", "pptx", "xlsx", "epub", "html", "csv", "json", "xml", "rtf", "doc", "odt", "m4a", "pdf", "png"] {
            let type = UTType(filenameExtension: ext)!
            XCTAssertTrue(types.contains { type.conforms(to: $0) }, ext)
        }
    }

    func testEveryNewKindConvertsToEveryFormat() {
        for kind in ConversionInput.allCases where kind != .markdown {
            XCTAssertEqual(kind.availableOutputs, [.markdown, .word, .html, .plainText], "\(kind)")
        }
    }

    func testErrorsNeverShowInternalNames() {
        let url = URL(fileURLWithPath: "/tmp/Deck.pptx")
        let errors: [ConversionError] = [
            .unsupportedInput(url),
            .unsupportedConversion(from: .presentation, to: .word),
            .passwordProtected(url),
            .requiresAsynchronousImport(url),
        ]
        let internalNames = ConversionInput.allCases.map(\.rawValue).filter { $0.contains(where: \.isUppercase) }
        for error in errors {
            let text = error.errorDescription ?? ""
            for name in internalNames {
                XCTAssertFalse(text.contains(name), "\(name) leaks into: \(text)")
            }
        }
        XCTAssertEqual(ConversionError.unsupportedConversion(from: .presentation, to: .word).errorDescription,
                       "Converting PowerPoint presentation to Word Document isn't supported.")
    }

    func testSynchronousConversionRefusesAudio() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("talk.m4a")
            try Data("x".utf8).write(to: url)
            XCTAssertThrowsError(try ConversionService().convert(fileAt: url, to: .markdown)) { error in
                guard case ConversionError.requiresAsynchronousImport = error else {
                    return XCTFail("unexpected \(error)")
                }
            }
        }
    }

    func testStructuredImportsFlowThroughToEveryFormat() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let csv = directory.appendingPathComponent("team.csv")
            try Data("Name,Role\nAda,Lead\n".utf8).write(to: csv)
            let service = ConversionService()
            XCTAssertEqual(try service.markdown(fromFileAt: csv), "| Name | Role |\n| --- | --- |\n| Ada | Lead |\n")
            let html = try service.convert(fileAt: csv, to: .html).text ?? ""
            XCTAssertTrue(html.contains("<table"), html)
            let word = try service.convert(fileAt: csv, to: .word)
            XCTAssertEqual(word.suggestedFilename, "team.docx")
            XCTAssertFalse(word.data.isEmpty)
        }
    }
}
