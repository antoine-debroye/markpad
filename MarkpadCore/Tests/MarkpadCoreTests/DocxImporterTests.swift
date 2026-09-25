import Foundation
import XCTest
@testable import MarkpadCore

/// Word documents are built by hand from minimal WordprocessingML, so each test pins one
/// construct and the exact Markdown it becomes.
final class DocxImporterTests: XCTestCase {
    // MARK: - Package builder

    private static let namespaces = """
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" \
    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
    xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" \
    xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" \
    xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"
    """

    private struct Package {
        var body: String
        var styles: String?
        var numbering: String?
        /// Extra `<Relationship>` elements for the document part.
        var relationships: [String] = []
        var files: [String: Data] = [:]
        /// Put the document somewhere other than word/document.xml, to prove the path is looked up.
        var documentPath = "word/document.xml"
    }

    private func build(_ package: Package) throws -> Data {
        var writer = ZipWriter()
        let docDir = (package.documentPath as NSString).deletingLastPathComponent
        let docName = (package.documentPath as NSString).lastPathComponent
        try writer.addFile(name: "[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/\(package.documentPath)" \
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """.utf8))
        try writer.addFile(name: "_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="\(package.documentPath)"/></Relationships>
        """.utf8))
        var relationships = package.relationships
        if let styles = package.styles {
            relationships.append("<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>")
            try writer.addFile(name: docDir + "/styles.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles \(Self.namespaces)>\(styles)</w:styles>
            """.utf8))
        }
        if let numbering = package.numbering {
            relationships.append("<Relationship Id=\"rIdNumbering\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>")
            try writer.addFile(name: docDir + "/numbering.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:numbering \(Self.namespaces)>\(numbering)</w:numbering>
            """.utf8))
        }
        try writer.addFile(name: docDir + "/_rels/" + docName + ".rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(relationships.joined())</Relationships>
        """.utf8))
        try writer.addFile(name: package.documentPath, data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(Self.namespaces)><w:body>\(package.body)<w:sectPr/></w:body></w:document>
        """.utf8))
        for (name, data) in package.files.sorted(by: { $0.key < $1.key }) {
            try writer.addFile(name: name, data: data)
        }
        return try writer.finalize()
    }

    private func convert(
        _ package: Package,
        options: DocumentImportOptions = .init(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ImportedMarkdown {
        let data = try build(package)
        return try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("test.docx")
            try data.write(to: url)
            return try DocxImporter().convert(url: url, options: options, progress: progress, isCancelled: isCancelled)
        }
    }

    private func markdown(_ body: String, styles: String? = nil, numbering: String? = nil, relationships: [String] = []) throws -> String {
        try convert(Package(body: body, styles: styles, numbering: numbering, relationships: relationships)).markdown
    }

    private func p(_ text: String, style: String? = nil) -> String {
        let pPr = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        return "<w:p>\(pPr)<w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p>"
    }

    private func style(_ id: String, name: String, type: String = "paragraph", basedOn: String? = nil, pPr: String = "", rPr: String = "") -> String {
        let based = basedOn.map { "<w:basedOn w:val=\"\($0)\"/>" } ?? ""
        return "<w:style w:type=\"\(type)\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/>\(based)"
            + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + (rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>") + "</w:style>"
    }

    private static let externalLink = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
    private static let imageType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x01, 0x02])
    private static let emf = Data([0x01, 0x00, 0x00, 0x00, 0x6C, 0x00, 0x00, 0x00, 0x20, 0x45, 0x4D, 0x46])

    // MARK: - Headings

    func testHeadingsFromStyleIDNameAndOutlineLevel() throws {
        let styles = [
            style("Normal", name: "Normal"),
            style("Title", name: "Title", rPr: "<w:b/>"),
            style("Subtitle", name: "Subtitle"),
            style("Heading2", name: "heading 2", rPr: "<w:b/>"),
            // A German Word file: localised id, English built-in name.
            style("berschrift1", name: "heading 1"),
            style("Chapter", name: "Chapter Title", pPr: "<w:outlineLvl w:val=\"2\"/>"),
            style("ChapterBig", name: "Chapter Big", basedOn: "Chapter"),
            style("Deep", name: "heading 9"),
        ].joined()
        let body = [
            p("Report", style: "Title"),
            p("A subtitle", style: "Subtitle"),
            p("Einleitung", style: "berschrift1"),
            p("Scope", style: "Heading2"),
            p("Inherited", style: "ChapterBig"),
            p("Very deep", style: "Deep"),
            "<w:p><w:pPr><w:outlineLvl w:val=\"1\"/></w:pPr><w:r><w:t>Direct outline</w:t></w:r></w:p>",
            "<w:p><w:pPr><w:pStyle w:val=\"Heading2\"/><w:outlineLvl w:val=\"9\"/></w:pPr><w:r><w:t>Body after all</w:t></w:r></w:p>",
        ].joined()
        XCTAssertEqual(try markdown(body, styles: styles), """
        # Report

        A subtitle

        # Einleitung

        ## Scope

        ### Inherited

        ###### Very deep

        ## Direct outline

        **Body after all**

        """)
    }

    // MARK: - Runs

    func testRunFormattingAndInheritedRunProperties() throws {
        let styles = [
            style("Normal", name: "Normal"),
            style("Aside", name: "Aside", rPr: "<w:i/>"),
            style("Strong", name: "Strong", type: "character", rPr: "<w:b/>"),
            style("HTMLCode", name: "HTML Code", type: "character"),
        ].joined()
        let body = """
        <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r>\
        <w:r><w:rPr><w:i w:val="true"/></w:rPr><w:t>italic</w:t></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r>\
        <w:r><w:rPr><w:strike/></w:rPr><w:t>gone</w:t></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r>\
        <w:r><w:rPr><w:dstrike/></w:rPr><w:t>twice</w:t></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r>\
        <w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>plain</w:t></w:r></w:p>\
        <w:p><w:pPr><w:pStyle w:val="Aside"/></w:pPr><w:r><w:t xml:space="preserve">styled </w:t></w:r>\
        <w:r><w:rPr><w:i w:val="false"/></w:rPr><w:t xml:space="preserve">upright </w:t></w:r>\
        <w:r><w:rPr><w:rStyle w:val="Strong"/><w:i w:val="0"/></w:rPr><w:t>strong</w:t></w:r></w:p>\
        <w:p><w:r><w:t xml:space="preserve">Run </w:t></w:r><w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/></w:rPr><w:t>make</w:t></w:r>\
        <w:r><w:t xml:space="preserve"> or </w:t></w:r><w:r><w:rPr><w:rStyle w:val="HTMLCode"/></w:rPr><w:t>ls -la</w:t></w:r></w:p>\
        <w:p><w:r><w:t>a</w:t><w:tab/><w:t>b</w:t><w:br/><w:t>c</w:t><w:br w:type="page"/><w:t>d</w:t>\
        <w:softHyphen/><w:t>e&#xAD;f</w:t><w:noBreakHyphen/><w:t>g</w:t></w:r>\
        <w:r><w:sym w:font="Symbol" w:char="F061"/><w:sym w:font="Wingdings" w:char="F0FC"/><w:sym w:char="2192"/></w:r></w:p>
        """
        XCTAssertEqual(try markdown(body, styles: styles), """
        **bold** *italic* ~~gone twice~~ plain

        *styled* upright **strong**

        Run `make` or `ls -la`

        a b\\
        cdef-gα→

        """)
    }

    // MARK: - Lists

    private let numbering = """
    <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>\
    <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>\
    <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>\
    <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/></w:lvl></w:abstractNum>\
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>\
    <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>\
    <w:num w:numId="3"><w:abstractNumId w:val="0"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:numFmt w:val="upperRoman"/></w:lvl></w:lvlOverride></w:num>
    """

    private func item(_ text: String, numID: Int, level: Int = 0) -> String {
        "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numID)\"/></w:numPr></w:pPr>"
            + "<w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    func testListsFromNumberingDirectAndInheritedFromStyle() throws {
        let styles = [
            style("Normal", name: "Normal"),
            style("ListBullet", name: "List Bullet", pPr: "<w:numPr><w:numId w:val=\"1\"/></w:numPr>"),
            style("ListNumber2", name: "List Number 2", pPr: "<w:numPr><w:ilvl w:val=\"1\"/><w:numId w:val=\"2\"/></w:numPr>"),
        ].joined()
        let body = [
            item("Apples", numID: 1),
            item("Green", numID: 1, level: 1),
            item("Pears", numID: 1),
            p("Between"),
            item("First", numID: 2),
            item("Sub a", numID: 2, level: 1),
            item("Second", numID: 2),
            p("Between"),
            p("From style", style: "ListBullet"),
            p("Nested from style", style: "ListNumber2"),
            p("Between"),
            item("Roman override", numID: 3),
            "<w:p><w:pPr><w:pStyle w:val=\"ListBullet\"/><w:numPr><w:numId w:val=\"0\"/></w:numPr></w:pPr><w:r><w:t>Numbering removed</w:t></w:r></w:p>",
        ].joined()
        XCTAssertEqual(try markdown(body, styles: styles, numbering: numbering), """
        - Apples
          - Green
        - Pears

        Between

        1. First
           1. Sub a
        2. Second

        Between

        - From style
          1. Nested from style

        Between

        1. Roman override

        Numbering removed

        """)
    }

    // MARK: - Tables

    func testTablesWithSpansMergesNestedTablesAndMultiParagraphCells() throws {
        func cell(_ content: String, props: String = "") -> String {
            "<w:tc>" + (props.isEmpty ? "" : "<w:tcPr>\(props)</w:tcPr>") + content + "</w:tc>"
        }
        let nested = "<w:tbl><w:tr>\(cell(p("x")))\(cell(p("y")))</w:tr><w:tr>\(cell(p("z")))</w:tr></w:tbl>"
        let body = """
        <w:tbl><w:tblPr/><w:tblGrid/>\
        <w:tr>\(cell(p("Name")))\(cell(p("Detail"), props: "<w:gridSpan w:val=\"2\"/>"))\(cell(p("Note")))</w:tr>\
        <w:tr>\(cell(p("Merged"), props: "<w:vMerge w:val=\"restart\"/>"))\(cell(p("a")))\(cell(p("b")))\(cell(p("First") + "<w:p/>" + p("Second")))</w:tr>\
        <w:tr>\(cell("<w:p/>", props: "<w:vMerge/>"))\(cell(nested))\(cell(p("c|d")))\(cell(p("**")))</w:tr>\
        </w:tbl>
        """
        XCTAssertEqual(try markdown(body), """
        | Name | Detail |  | Note |
        | --- | --- | --- | --- |
        | Merged | a | b | First Second |
        |  | x y z | c\\|d | \\*\\* |

        """)
    }

    // MARK: - Hyperlinks and fields

    func testHyperlinksFromRelationshipsAnchorsAndFields() throws {
        let relationships = [
            "<Relationship Id=\"rIdLink\" Type=\"\(Self.externalLink)\" Target=\"https://example.com/a\" TargetMode=\"External\"/>",
        ]
        let body = """
        <w:p><w:r><w:t xml:space="preserve">See </w:t></w:r>\
        <w:hyperlink r:id="rIdLink"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr><w:t>the site</w:t></w:r></w:hyperlink>\
        <w:r><w:t xml:space="preserve"> and </w:t></w:r>\
        <w:hyperlink w:anchor="_Toc1"><w:r><w:t>section 2</w:t></w:r></w:hyperlink><w:r><w:t>.</w:t></w:r></w:p>\
        <w:p><w:fldSimple w:instr=" HYPERLINK &quot;https://example.org/simple&quot; "><w:r><w:t>simple field</w:t></w:r></w:fldSimple></w:p>\
        <w:p><w:r><w:t xml:space="preserve">Go to </w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> HYPERLINK </w:instrText></w:r>\
        <w:r><w:instrText xml:space="preserve">"https://example.net/complex" \\o "tip"</w:instrText></w:r>\
        <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>complex</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve"> field</w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t xml:space="preserve"> now.</w:t></w:r></w:p>\
        <w:p><w:r><w:t xml:space="preserve">Page </w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r>\
        <w:r><w:instrText>PAGE</w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>7</w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t xml:space="preserve"> and </w:t></w:r>\
        <w:fldSimple w:instr="HYPERLINK \\l &quot;bookmark&quot;"><w:r><w:t>internal</w:t></w:r></w:fldSimple></w:p>
        """
        XCTAssertEqual(try markdown(body, relationships: relationships), """
        See [the site](https://example.com/a) and section 2.

        [simple field](https://example.org/simple)

        Go to [complex **field**](https://example.net/complex) now.

        Page 7 and internal

        """)
    }

    func testFieldInstructionParsing() {
        XCTAssertEqual(DocxBodyReader.hyperlinkTarget(instruction: " HYPERLINK \"https://a.b/c\" \\l \"part\" "), "https://a.b/c#part")
        XCTAssertEqual(DocxBodyReader.hyperlinkTarget(instruction: "HYPERLINK https://a.b/plain"), "https://a.b/plain")
        XCTAssertNil(DocxBodyReader.hyperlinkTarget(instruction: "HYPERLINK \\l \"_Toc123\""))
        XCTAssertNil(DocxBodyReader.hyperlinkTarget(instruction: "PAGEREF _Toc123 \\h"))
    }

    // MARK: - Revisions, content controls, compatibility

    func testTrackedChangesContentControlsAndAlternateContent() throws {
        let body = """
        <w:p><w:r><w:t xml:space="preserve">Kept </w:t></w:r>\
        <w:ins w:id="1" w:author="A"><w:r><w:t xml:space="preserve">inserted </w:t></w:r></w:ins>\
        <w:del w:id="2" w:author="A"><w:r><w:delText xml:space="preserve">deleted </w:delText></w:r></w:del>\
        <w:r><w:t>text</w:t></w:r><w:r><w:commentReference w:id="0"/></w:r><w:r><w:footnoteReference w:id="1"/></w:r></w:p>\
        <w:sdt><w:sdtPr><w:alias w:val="Block"/><w:text/></w:sdtPr><w:sdtContent>\(p("Block control"))</w:sdtContent></w:sdt>\
        <w:p><w:r><w:t xml:space="preserve">Inline </w:t></w:r><w:sdt><w:sdtPr><w:showingPlcHdr/></w:sdtPr><w:sdtContent>\
        <w:r><w:t>control</w:t></w:r></w:sdtContent></w:sdt></w:p>\
        <w:del w:id="3" w:author="A">\(p("Deleted paragraph"))</w:del>\
        <w:p><mc:AlternateContent><mc:Choice Requires="wps"><w:r><w:t>choice</w:t></w:r></mc:Choice>\
        <mc:Fallback><w:r><w:t>fallback</w:t></w:r></mc:Fallback></mc:AlternateContent></w:p>\
        <w:p><w:r><mc:AlternateContent><mc:Choice Requires="w14"></mc:Choice>\
        <mc:Fallback><w:t>only fallback</w:t></mc:Fallback></mc:AlternateContent></w:r></w:p>
        """
        XCTAssertEqual(try markdown(body), """
        Kept inserted text

        Block control

        Inline control

        choice

        only fallback

        """)
    }

    func testTextBoxesPreferChoiceAndMathKeepsItsText() throws {
        let textBox = """
        <w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wp:anchor><wp:docPr id="3" name="Text Box 3"/>\
        <a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><wps:wsp><wps:txbx>\
        <w:txbxContent>\(p("Boxed text"))</w:txbxContent></wps:txbx></wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing>\
        </mc:Choice><mc:Fallback><w:pict><v:shape><v:textbox><w:txbxContent>\(p("Boxed text again"))</w:txbxContent>\
        </v:textbox></v:shape></w:pict></mc:Fallback></mc:AlternateContent></w:r>
        """
        let body = """
        <w:p><w:r><w:t>Host paragraph</w:t></w:r>\(textBox)</w:p>\
        <w:p><w:r><w:t xml:space="preserve">Area is </w:t></w:r><m:oMath><m:r><m:t>πr</m:t></m:r><m:sSup><m:e><m:r><m:t>2</m:t></m:r></m:e></m:sSup></m:oMath></w:p>
        """
        XCTAssertEqual(try markdown(body), """
        Host paragraph

        Boxed text

        Area is πr2

        """)
    }

    // MARK: - Pictures

    private func inlineDrawing(_ id: String, descr: String? = nil, title: String? = nil) -> String {
        var attributes = "id=\"1\" name=\"Picture 1\""
        if let descr { attributes += " descr=\"\(descr)\"" }
        if let title { attributes += " title=\"\(title)\"" }
        return """
        <w:r><w:drawing><wp:inline><wp:extent cx="100" cy="100"/><wp:docPr \(attributes)/>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="p.png"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(id)"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    private func anchorDrawing(_ id: String, descr: String) -> String {
        """
        <w:r><w:drawing><wp:anchor behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1" relativeHeight="1" simplePos="0">\
        <wp:simplePos x="0" y="0"/><wp:extent cx="100" cy="100"/><wp:wrapSquare wrapText="bothSides"/>\
        <wp:docPr id="2" name="Picture 2" descr="\(descr)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:blipFill><a:blip r:embed="\(id)"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>
        """
    }

    private var picturePackage: Package {
        let relationships = [
            "<Relationship Id=\"rIdPng\" Type=\"\(Self.imageType)\" Target=\"media/image1.png\"/>",
            "<Relationship Id=\"rIdEmf\" Type=\"\(Self.imageType)\" Target=\"media/image2.emf\"/>",
            "<Relationship Id=\"rIdVml\" Type=\"\(Self.imageType)\" Target=\"media/image3.emf\"/>",
        ]
        let legacy = """
        <w:r><w:pict><v:shape id="s1" style="width:10pt;height:10pt"><v:imagedata r:id="rIdVml" o:title="Old chart"/></v:shape></w:pict></w:r>
        """
        let alternate = """
        <w:r><mc:AlternateContent><mc:Choice Requires="wps">\(inlineDrawing("rIdPng", descr: "Logo").dropFirst(5).dropLast(6))</mc:Choice>\
        <mc:Fallback><w:pict><v:shape><v:imagedata r:id="rIdEmf"/></v:shape></w:pict></mc:Fallback></mc:AlternateContent></w:r>
        """
        let body = [
            "<w:p>\(inlineDrawing("rIdPng", descr: "Company logo"))</w:p>",
            "<w:p><w:r><w:t xml:space=\"preserve\">Inline </w:t></w:r>\(inlineDrawing("rIdPng", title: "Title only"))<w:r><w:t xml:space=\"preserve\"> here</w:t></w:r></w:p>",
            "<w:p>\(anchorDrawing("rIdEmf", descr: "Floating diagram"))</w:p>",
            "<w:p>\(legacy)</w:p>",
            "<w:p>\(alternate)</w:p>",
            "<w:p>\(inlineDrawing("rIdPng"))</w:p>",
            p("End"),
        ].joined()
        return Package(body: body, relationships: relationships, files: [
            "word/media/image1.png": Self.png,
            "word/media/image2.emf": Self.emf,
            "word/media/image3.emf": Self.emf + Data([0x01]),
        ])
    }

    func testPicturesBecomeAssetsWithAltTextAndMetafileNotice() throws {
        let result = try convert(picturePackage, options: .init(assetFolderName: "Doc_assets"))
        XCTAssertEqual(result.markdown, """
        ![Company logo](Doc_assets/image1.png)

        Inline ![Title only](Doc_assets/image1.png) here

        ![Floating diagram](Doc_assets/image2.emf)

        ![Old chart](Doc_assets/image3.emf)

        ![Logo](Doc_assets/image1.png)

        ![](Doc_assets/image1.png)

        End

        """)
        XCTAssertEqual(result.assets.map(\.name), ["image1.png", "image2.emf", "image3.emf"])
        XCTAssertEqual(result.assets.first?.data, Self.png)
        XCTAssertEqual(result.notices, [DocxBodyReader.metafileNotice])
        XCTAssertEqual(DocxBodyReader.metafileNotice,
                       "Some pictures are Windows metafiles (EMF/WMF), which may not display on a Mac.")
    }

    func testPicturesWithoutAssetFolderFallBackToAltText() throws {
        let result = try convert(picturePackage, options: .init(assetFolderName: nil))
        XCTAssertEqual(result.markdown, """
        Company logo

        Inline Title only here

        Floating diagram

        Old chart

        Logo

        End

        """)
        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertTrue(result.notices.isEmpty)
    }

    // MARK: - Quotes and code

    func testQuoteAndCodeStyles() throws {
        let styles = [
            style("Normal", name: "Normal"),
            style("Quote", name: "Quote", rPr: "<w:i/>"),
            style("IntenseQuote", name: "Intense Quote"),
            style("SourceCode", name: "Source Code", rPr: "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>"),
            style("HTMLPreformatted", name: "HTML Preformatted"),
        ].joined()
        let mono = "<w:rPr><w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\"/></w:rPr>"
        let body = [
            p("To be or not to be.", style: "Quote"),
            p("Intense.", style: "IntenseQuote"),
            p("func main() {", style: "SourceCode"),
            "<w:p><w:pPr><w:pStyle w:val=\"SourceCode\"/></w:pPr></w:p>",
            "<w:p><w:pPr><w:pStyle w:val=\"SourceCode\"/></w:pPr><w:r><w:tab/><w:t>print(\"*hi*\")</w:t></w:r></w:p>",
            p("}", style: "SourceCode"),
            p("Between"),
            p("&lt;pre&gt;", style: "HTMLPreformatted"),
            p("Between"),
            "<w:p><w:r>\(mono)<w:t>let x = 1</w:t></w:r></w:p>",
            "<w:p><w:r>\(mono)<w:t>let y = 2</w:t></w:r></w:p>",
        ].joined()
        XCTAssertEqual(try markdown(body, styles: styles), """
        > To be or not to be.

        > Intense.

        ```
        func main() {

        \tprint("*hi*")
        }
        ```

        Between

        ```
        <pre>
        ```

        Between

        ```
        let x = 1
        let y = 2
        ```

        """)
    }

    // MARK: - Package handling and errors

    func testMainPartIsFoundThroughRelationships() throws {
        var package = Package(body: p("Elsewhere"))
        package.documentPath = "content/main.xml"
        XCTAssertEqual(try convert(package).markdown, "Elsewhere\n")
    }

    func testEmptyParagraphsAreDroppedAndEmptyDocumentHasNoText() throws {
        XCTAssertEqual(try markdown("<w:p/>" + p("One") + "<w:p><w:r><w:t xml:space=\"preserve\">   </w:t></w:r></w:p>" + p("Two")),
                       "One\n\nTwo\n")
        XCTAssertThrowsError(try markdown("<w:p/><w:p><w:r><w:t> </w:t></w:r></w:p>")) { error in
            guard case ConversionError.noTextFound = error else { return XCTFail("\(error)") }
        }
    }

    func testDamagedAndProtectedFilesAreReported() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let garbage = directory.appendingPathComponent("garbage.docx")
            try Data("not a zip at all".utf8).write(to: garbage)
            XCTAssertThrowsError(try DocxImporter().convert(url: garbage)) { error in
                guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
            }

            let protected = directory.appendingPathComponent("protected.docx")
            try Data(ZipReader.compoundFileSignature + [UInt8](repeating: 0, count: 504)).write(to: protected)
            XCTAssertThrowsError(try DocxImporter().convert(url: protected)) { error in
                guard case ConversionError.passwordProtected = error else { return XCTFail("\(error)") }
            }

            var writer = ZipWriter()
            try writer.addFile(name: "hello.txt", data: Data("hi".utf8))
            let noDocument = directory.appendingPathComponent("empty.docx")
            try writer.finalize().write(to: noDocument)
            XCTAssertThrowsError(try DocxImporter().convert(url: noDocument)) { error in
                guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
            }

            var broken = ZipWriter()
            try broken.addFile(name: "word/document.xml", data: Data("<w:document><w:body>".utf8))
            let malformed = directory.appendingPathComponent("malformed.docx")
            try broken.finalize().write(to: malformed)
            XCTAssertThrowsError(try DocxImporter().convert(url: malformed)) { error in
                guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testProgressReportsReadingThenExtractingAndCancellationIsHonoured() throws {
        let body = (1...120).map { p("Paragraph \($0)") }.joined()
        let phases = LockedPhases()
        _ = try convert(Package(body: body), progress: { phases.append($0) })
        let recorded = phases.values
        XCTAssertEqual(recorded.first?.phase, .reading)
        XCTAssertEqual(recorded.dropFirst().first?.phase, .extractingText)
        XCTAssertEqual(recorded.last?.fractionCompleted, 1)
        XCTAssertEqual(recorded.map(\.fractionCompleted), recorded.map(\.fractionCompleted).sorted())

        let calls = LockedPhases()
        XCTAssertThrowsError(try convert(Package(body: body), isCancelled: {
            // Cancel once reading is under way, so the per-50-paragraph check is what stops it.
            calls.count() > 3
        })) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Independent writers

    func testRoundTripThroughDocxExporter() throws {
        let source = """
        # Title

        Intro with a [link](https://example.com/x) and **bold** text.

        ## Section

        - one
          - nested
        - two
        1. first
        2. second

        | A | B |
        | --- | --- |
        | 1 | 2 |

        > Quoted words.

        ```
        code line
        ```

        """
        let data = try DocxExporter().export(markdown: source)
        let markdown = try Fixtures.withTemporaryDirectory { directory -> String in
            let url = directory.appendingPathComponent("round.docx")
            try data.write(to: url)
            return try DocxImporter().convert(url: url).markdown
        }
        XCTAssertEqual(markdown, source)
    }

    /// A file from an independent writer: Cocoa's, via textutil. It uses no paragraph styles,
    /// numbering or hyperlink elements — lists are literal "\t•\t" text and tables are written
    /// as one paragraph per cell — so only what it actually encodes is asserted.
    func testFileWrittenByTextutil() throws {
        let textutil = URL(fileURLWithPath: "/usr/bin/textutil")
        guard FileManager.default.isExecutableFile(atPath: textutil.path) else {
            throw XCTSkip("textutil is not available")
        }
        let html = """
        <html><body><h1>Main Title</h1><p>Some <b>bold</b> and <i>italic</i> text with \
        <a href="https://example.com/page">a link</a>.</p><h2>Section Two</h2>\
        <ul><li>Apple<ul><li>Green</li></ul></li><li>Banana</li></ul><ol><li>First</li><li>Second</li></ol>\
        <table><tr><th>Name</th><th>Qty</th></tr><tr><td>Pear</td><td>3</td></tr></table></body></html>
        """
        let markdown = try Fixtures.withTemporaryDirectory { directory -> String in
            let input = directory.appendingPathComponent("in.html")
            let output = directory.appendingPathComponent("out.docx")
            try Data(html.utf8).write(to: input)
            let process = Process()
            process.executableURL = textutil
            process.arguments = ["-convert", "docx", input.path, "-output", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("textutil failed with \(process.terminationStatus)") }
            return try DocxImporter().convert(url: output).markdown
        }
        XCTAssertEqual(markdown, """
        **Main Title**

        Some **bold** and *italic* text with a link.

        **Section Two**

        - Apple
          - Green
        - Banana
        1. First
        2. Second

        **Name**

        **Qty**

        Pear

        3

        """)
    }
}

/// Collects progress callbacks from the worker thread.
private final class LockedPhases: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ImportProgress] = []
    private var calls = 0

    func append(_ progress: ImportProgress) {
        lock.lock(); defer { lock.unlock() }
        stored.append(progress)
    }

    var values: [ImportProgress] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls
    }
}
