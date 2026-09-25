import Foundation
import XCTest
@testable import MarkpadCore

/// Builds minimal but valid OPC packages (`.pptx`, `.xlsx`) from XML strings.
struct OfficeTestPackage {
    struct Relationship {
        let id: String
        let type: String
        let target: String
        var external = false
    }

    static let relationshipBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private(set) var parts: [(name: String, data: Data)] = []

    mutating func add(_ name: String, _ xml: String) {
        parts.append((name, Data(xml.utf8)))
    }

    mutating func add(_ name: String, data: Data) {
        parts.append((name, data))
    }

    mutating func addRelationships(for part: String, _ relationships: [Relationship]) {
        let body = relationships.map { relationship in
            "<Relationship Id=\"\(relationship.id)\" Type=\"\(Self.relationshipBase)\(relationship.type)\" Target=\"\(relationship.target)\""
                + (relationship.external ? " TargetMode=\"External\"" : "") + "/>"
        }.joined()
        add(OfficeImportRelationships.path(for: part),
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(body)</Relationships>")
    }

    /// `[Content_Types].xml` with the given overrides, plus the package relationship to the
    /// main part.
    mutating func addPackageBasics(mainPart: String, overrides: [String: String]) {
        let overrideXML = overrides.sorted { $0.key < $1.key }.map {
            "<Override PartName=\"/\($0.key)\" ContentType=\"\($0.value)\"/>"
        }.joined()
        add("[Content_Types].xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Default Extension=\"png\" ContentType=\"image/png\"/>"
                + overrideXML + "</Types>")
        addRelationships(for: "", [Relationship(id: "rId1", type: "officeDocument", target: mainPart)])
    }

    func write(to url: URL) throws {
        var writer = ZipWriter()
        for part in parts { try writer.addFile(name: part.name, data: part.data) }
        try writer.finalize().write(to: url)
    }
}

final class PresentationImporterTests: XCTestCase {
    private static let namespaces = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        + "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])

    // MARK: - XML helpers

    private static func slide(_ shapes: String, hidden: Bool = false) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:sld \(namespaces)\(hidden ? " show=\"0\"" : "")>"
            + "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
            + shapes + "</p:spTree></p:cSld></p:sld>"
    }

    private static func notes(_ shapes: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:notes \(namespaces)>"
            + "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
            + shapes + "</p:spTree></p:cSld></p:notes>"
    }

    /// A shape; `placeholder` is the `p:ph` type ("" for a typeless placeholder, nil for none).
    private static func shape(_ placeholder: String?, _ paragraphs: String) -> String {
        let ph: String
        switch placeholder {
        case nil: ph = ""
        case "": ph = "<p:ph idx=\"1\"/>"
        case let type?: ph = "<p:ph type=\"\(type)\"/>"
        }
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Shape\"/><p:cNvSpPr/><p:nvPr>\(ph)</p:nvPr></p:nvSpPr><p:spPr/>"
            + "<p:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>"
    }

    private static func paragraph(_ runs: String, properties: String = "") -> String {
        "<a:p>\(properties)\(runs)<a:endParaRPr lang=\"en-GB\"/></a:p>"
    }

    private static func run(_ text: String, attributes: String = "", inner: String = "") -> String {
        "<a:r><a:rPr lang=\"en-GB\" \(attributes)>\(inner)</a:rPr><a:t>\(text)</a:t></a:r>"
    }

    private static func cell(_ text: String, attributes: String = "") -> String {
        "<a:tc \(attributes)><a:txBody><a:bodyPr/><a:lstStyle/>" + paragraph(text.isEmpty ? "" : run(text))
            + "</a:txBody><a:tcPr/></a:tc>"
    }

    // MARK: - Fixture deck

    /// Three slides whose part names run in a different order from the deck.
    private static func writeDeck(to url: URL) throws {
        var package = OfficeTestPackage()
        package.addPackageBasics(mainPart: "ppt/presentation.xml", overrides: [
            "ppt/presentation.xml": "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
            "ppt/slides/slide1.xml": "application/vnd.openxmlformats-officedocument.presentationml.slide+xml",
            "ppt/slides/slide2.xml": "application/vnd.openxmlformats-officedocument.presentationml.slide+xml",
            "ppt/slides/slide3.xml": "application/vnd.openxmlformats-officedocument.presentationml.slide+xml",
            "ppt/notesSlides/notesSlide1.xml": "application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"
        ])
        package.add("ppt/presentation.xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:presentation \(namespaces)>"
                + "<p:sldIdLst><p:sldId id=\"256\" r:id=\"rId3\"/><p:sldId id=\"257\" r:id=\"rId2\"/><p:sldId id=\"258\" r:id=\"rId4\"/></p:sldIdLst>"
                + "<p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        package.addRelationships(for: "ppt/presentation.xml", [
            .init(id: "rId2", type: "slide", target: "slides/slide1.xml"),
            .init(id: "rId3", type: "slide", target: "slides/slide2.xml"),
            .init(id: "rId4", type: "slide", target: "slides/slide3.xml")
        ])

        // Deck slide 1 (part slide2.xml): body before title in the stacking order, bullets,
        // levels, a link, a numbered text box and notes.
        let body = shape("body",
            paragraph(run("Revenue ") + run("up", attributes: "b=\"1\""))
            + paragraph(run("Europe"), properties: "<a:pPr lvl=\"1\"/>")
            + paragraph(run("Plain line"), properties: "<a:pPr><a:buNone/></a:pPr>")
            + paragraph(run("Visit site", inner: "<a:hlinkClick r:id=\"rId7\"/>"))
            + paragraph(""))
        let numbered = shape(nil,
            paragraph(run("First"), properties: "<a:pPr marL=\"342900\" indent=\"-342900\"><a:buFont typeface=\"+mj-lt\"/><a:buAutoNum type=\"arabicPeriod\"/></a:pPr>")
            + paragraph(run("Second"), properties: "<a:pPr><a:buAutoNum type=\"arabicPeriod\"/></a:pPr>")
            + paragraph(run("Note:", attributes: "i=\"1\"") + run(" gone", attributes: "strike=\"sngStrike\"")
                + "<a:br><a:rPr lang=\"en-GB\"/></a:br>" + run("next line", attributes: "strike=\"noStrike\"")))
        package.add("ppt/slides/slide2.xml", slide(body + shape("title", paragraph(run("Q3 Review"))) + numbered))
        package.addRelationships(for: "ppt/slides/slide2.xml", [
            .init(id: "rId1", type: "slideLayout", target: "../slideLayouts/slideLayout2.xml"),
            .init(id: "rId2", type: "notesSlide", target: "../notesSlides/notesSlide1.xml"),
            .init(id: "rId7", type: "hyperlink", target: "https://example.com/", external: true)
        ])
        package.add("ppt/notesSlides/notesSlide1.xml", notes(
            shape("sldImg", "")
            + shape("body", paragraph(run("Say hello")) + paragraph(run("Then ") + run("smile", attributes: "b=\"1\"")))
            + shape("sldNum", paragraph("<a:fld id=\"{1}\" type=\"slidenum\"><a:t>1</a:t></a:fld>"))))

        // Deck slide 2 (part slide1.xml): centred title, subtitle, a merged table, a picture
        // and a chart.
        let table = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"4\" name=\"Table\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>"
            + "<p:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"1\" cy=\"1\"/></p:xfrm><a:graphic>"
            + "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblPr/>"
            + "<a:tblGrid><a:gridCol w=\"1\"/><a:gridCol w=\"1\"/><a:gridCol w=\"1\"/></a:tblGrid>"
            + "<a:tr h=\"1\">" + cell("Name") + cell("Q1") + cell("Q2") + "</a:tr>"
            + "<a:tr h=\"1\">" + cell("Both quarters", attributes: "gridSpan=\"2\"") + cell("hidden", attributes: "hMerge=\"1\"")
            + cell("Total", attributes: "rowSpan=\"2\"") + "</a:tr>"
            + "<a:tr h=\"1\">" + cell("A") + cell("1") + cell("covered", attributes: "vMerge=\"1\"") + "</a:tr>"
            + "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let picture = "<p:pic><p:nvPicPr><p:cNvPr id=\"5\" name=\"Picture 4\" descr=\"A red dot\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>"
            + "<p:blipFill><a:blip r:embed=\"rId3\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr/></p:pic>"
        let chart = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"6\" name=\"Chart\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>"
            + "<p:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"1\" cy=\"1\"/></p:xfrm><a:graphic>"
            + "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\">"
            + "<c:chart xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" r:id=\"rId4\"/>"
            + "</a:graphicData></a:graphic></p:graphicFrame>"
        package.add("ppt/slides/slide1.xml", slide(
            shape("ctrTitle", paragraph(run("Welcome")))
            + shape("subTitle", paragraph(run("An overview")))
            + table + picture + chart))
        package.addRelationships(for: "ppt/slides/slide1.xml", [
            .init(id: "rId1", type: "slideLayout", target: "../slideLayouts/slideLayout1.xml"),
            .init(id: "rId3", type: "image", target: "../media/image1.png"),
            .init(id: "rId4", type: "chart", target: "../charts/chart1.xml")
        ])
        package.add("ppt/media/image1.png", data: png)

        // Deck slide 3: hidden, with a group and footer chrome.
        package.add("ppt/slides/slide3.xml", slide(
            shape("title", paragraph(run("Appendix")))
            + "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"7\" name=\"Group\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
            + shape(nil, paragraph(run("Grouped text"))) + "</p:grpSp>"
            + shape("dt", paragraph(run("25/09/2026")))
            + shape("sldNum", paragraph("<a:fld id=\"{2}\" type=\"slidenum\"><a:t>3</a:t></a:fld>"))
            + shape("", paragraph(run("Content placeholder"))),
            hidden: true))
        package.addRelationships(for: "ppt/slides/slide3.xml", [
            .init(id: "rId1", type: "slideLayout", target: "../slideLayouts/slideLayout2.xml")
        ])
        try package.write(to: url)
    }

    private static let expectedDeck = """
        <!-- Slide 1 -->

        ## Q3 Review

        - Revenue **up**
          - Europe

        Plain line

        - [Visit site](https://example.com/)
        1. First
        2. Second

        *Note:* ~~gone~~\\
        next line

        ### Notes

        Say hello

        Then **smile**

        <!-- Slide 2 -->

        ## Welcome

        An overview

        | Name | Q1 | Q2 |
        | --- | --- | --- |
        | Both quarters |  | Total |
        | A | 1 |  |

        %@

        <!-- Slide 3 -->

        ## Appendix

        Grouped text

        - Content placeholder

        """

    // MARK: - Tests

    func testConvertsDeckInPresentationOrder() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Deck.pptx")
            try Self.writeDeck(to: url)
            let result = try PresentationImporter().convert(url: url, options: .init(assetFolderName: "Deck_assets"))
            XCTAssertEqual(result.markdown, Self.expectedDeck.replacingOccurrences(of: "%@", with: "![A red dot](Deck_assets/image1.png)"))
            XCTAssertEqual(result.assets, [.init(name: "image1.png", data: Self.png)])
            XCTAssertEqual(result.notices, ["Charts and SmartArt were left out."])
        }
    }

    func testPicturesFallBackToAltTextWithoutAssetFolder() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Deck.pptx")
            try Self.writeDeck(to: url)
            let result = try PresentationImporter().convert(url: url)
            XCTAssertEqual(result.markdown, Self.expectedDeck.replacingOccurrences(of: "%@", with: "A red dot"))
            XCTAssertEqual(result.assets, [])
        }
    }

    func testReportsProgressPerSlideAndCancels() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Deck.pptx")
            try Self.writeDeck(to: url)
            let log = ProgressLog()
            _ = try PresentationImporter().convert(url: url, progress: log.handler)
            XCTAssertEqual(log.pageEvents.map(\.unit), [1, 2, 3])
            XCTAssertTrue(log.all.allSatisfy { $0.unitKind == .slide && $0.totalUnits == 3 })
            XCTAssertEqual(log.all.last?.fractionCompleted, 1)

            XCTAssertThrowsError(try PresentationImporter().convert(url: url, isCancelled: { true })) { error in
                guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testEmptyDeckHasNoText() throws {
        try Fixtures.withTemporaryDirectory { directory in
            var package = OfficeTestPackage()
            package.addPackageBasics(mainPart: "ppt/presentation.xml", overrides: [:])
            package.add("ppt/presentation.xml", "<p:presentation \(Self.namespaces)><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId2\"/></p:sldIdLst></p:presentation>")
            package.addRelationships(for: "ppt/presentation.xml", [.init(id: "rId2", type: "slide", target: "slides/slide1.xml")])
            package.add("ppt/slides/slide1.xml", Self.slide(Self.shape("title", Self.paragraph(""))))
            let url = directory.appendingPathComponent("Empty.pptx")
            try package.write(to: url)
            XCTAssertThrowsError(try PresentationImporter().convert(url: url)) { error in
                guard case ConversionError.noTextFound = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testRejectsPasswordProtectedAndDamagedFiles() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let locked = directory.appendingPathComponent("Locked.pptx")
            var data = Data(ZipReader.compoundFileSignature)
            data.append(Data(count: 1024))
            try data.write(to: locked)
            XCTAssertThrowsError(try PresentationImporter().convert(url: locked)) { error in
                guard case ConversionError.passwordProtected = error else { return XCTFail("\(error)") }
            }

            let garbage = directory.appendingPathComponent("Garbage.pptx")
            try Data("definitely not a presentation".utf8).write(to: garbage)
            XCTAssertThrowsError(try PresentationImporter().convert(url: garbage)) { error in
                guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
            }

            // A ZIP that is not a presentation.
            var other = OfficeTestPackage()
            other.add("hello.txt", "hi")
            let wrong = directory.appendingPathComponent("Wrong.pptx")
            try other.write(to: wrong)
            XCTAssertThrowsError(try PresentationImporter().convert(url: wrong)) { error in
                guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
            }
        }
    }

    /// A deck written by an independent implementation (python-pptx), when one is installed.
    func testReadsDeckFromPythonPptx() throws {
        let python = ["/usr/bin/env"]
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Python.pptx")
            let script = """
                import sys
                from pptx import Presentation
                from pptx.util import Inches
                deck = Presentation()
                s = deck.slides.add_slide(deck.slide_layouts[1])
                s.shapes.title.text = "Made elsewhere"
                body = s.placeholders[1].text_frame
                body.text = "Point one"
                p = body.add_paragraph(); p.text = "Sub point"; p.level = 1
                s.notes_slide.notes_text_frame.text = "Remember this"
                s2 = deck.slides.add_slide(deck.slide_layouts[5])
                s2.shapes.title.text = "Table"
                t = s2.shapes.add_table(2, 2, Inches(1), Inches(2), Inches(4), Inches(1)).table
                t.cell(0, 0).text = "H1"; t.cell(0, 1).text = "H2"; t.cell(1, 0).text = "a"; t.cell(1, 1).text = "b"
                deck.save(sys.argv[1])
                """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python[0])
            process.arguments = ["python3", "-c", script, url.path]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            do { try process.run() } catch { throw XCTSkip("python3 is not available") }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("python-pptx is not installed") }

            let result = try PresentationImporter().convert(url: url)
            XCTAssertEqual(result.markdown, """
                <!-- Slide 1 -->

                ## Made elsewhere

                - Point one
                  - Sub point

                ### Notes

                Remember this

                <!-- Slide 2 -->

                ## Table

                | H1 | H2 |
                | --- | --- |
                | a | b |

                """)
        }
    }
}
