import XCTest
@testable import MarkpadCore

/// Diagram rendering itself needs a web view and lives in the app, so what is checked here
/// is the part the app depends on: which blocks count as diagrams, and how they are exported
/// with and without a rendered picture available.
final class DiagramDetectionTests: XCTestCase {
    private let engine = StyleEngine()

    func testMermaidBlockIsRecognisedAsADiagram() throws {
        let source = "```mermaid\nflowchart LR\n  A --> B\n```\n"
        let layout = engine.layout(for: source)

        XCTAssertEqual(layout.diagrams.count, 1)
        let diagram = try XCTUnwrap(layout.diagrams.first)
        XCTAssertEqual(diagram.language, "mermaid")
        XCTAssertEqual(diagram.source, "flowchart LR\n  A --> B\n")
        // The picture replaces the whole block, fences included.
        XCTAssertEqual((source as NSString).substring(with: diagram.range).hasPrefix("```mermaid"), true)
    }

    func testLanguageMatchIsCaseInsensitive() {
        XCTAssertEqual(engine.layout(for: "```Mermaid\nflowchart LR\n```\n").diagrams.count, 1)
        XCTAssertTrue(DiagramLanguage.isDiagram("MERMAID"))
        XCTAssertFalse(DiagramLanguage.isDiagram("swift"))
    }

    func testDiagramBlocksAreNotSyntaxHighlighted() {
        let layout = engine.layout(for: "```mermaid\nflowchart LR\n  A --> B\n```\n")
        XCTAssertTrue(layout.code.isEmpty, "a diagram is a picture, not code to colour")
    }

    func testOrdinaryCodeBlocksAreNotDiagrams() {
        let layout = engine.layout(for: "```swift\nlet a = 1\n```\n")
        XCTAssertTrue(layout.diagrams.isEmpty)
        XCTAssertFalse(layout.code.isEmpty)
    }

    func testDiagramRangeStaysInsideTheDocument() {
        let source = "text\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\nmore\n"
        let length = (source as NSString).length
        for diagram in engine.layout(for: source).diagrams {
            XCTAssertLessThanOrEqual(NSMaxRange(diagram.range), length)
        }
    }
}

final class DiagramExportTests: XCTestCase {
    private let markdown = "```mermaid\nflowchart LR\n  A --> B\n```\n"

    func testRenderedDiagramIsEmbeddedAsSVG() {
        let options = HTMLExporter.Options(
            standalone: false,
            diagramResolver: { _ in "<svg id=\"drawn\"></svg>" }
        )
        let html = HTMLExporter().export(markdown: markdown, options: options)
        XCTAssertTrue(html.contains("<figure class=\"diagram\">"), html)
        XCTAssertTrue(html.contains("<svg id=\"drawn\">"), html)
        XCTAssertFalse(html.contains("<pre>"), "the diagram should replace the code block")
    }

    func testResolverReceivesTheDiagramSource() {
        var seen: String?
        let options = HTMLExporter.Options(
            standalone: false,
            diagramResolver: { source in seen = source; return "<svg></svg>" }
        )
        _ = HTMLExporter().export(markdown: markdown, options: options)
        XCTAssertEqual(seen, "flowchart LR\n  A --> B\n")
    }

    func testWithoutARendererTheDiagramIsWrittenOutAsCode() {
        // Losing the diagram's contents entirely would be worse than showing its source.
        let html = HTMLExporter().export(markdown: markdown, options: .init(standalone: false))
        XCTAssertTrue(html.contains("<pre><code class=\"language-mermaid\">"), html)
        XCTAssertTrue(html.contains("flowchart LR"), html)
    }

    func testUnrenderableDiagramFallsBackToCode() {
        let options = HTMLExporter.Options(standalone: false, diagramResolver: { _ in nil })
        let html = HTMLExporter().export(markdown: markdown, options: options)
        XCTAssertTrue(html.contains("<pre>"), html)
    }

    func testConversionServicePassesRenderedDiagramsThrough() throws {
        var service = ConversionService()
        service.diagrams = ["flowchart LR\n  A --> B\n": "<svg id=\"from-service\"></svg>"]

        let result = try service.convert(markdown: markdown, to: .html)
        let html = try XCTUnwrap(result.text)
        XCTAssertTrue(html.contains("<svg id=\"from-service\">"), html)
        XCTAssertTrue(html.contains(".diagram"), "the stylesheet should style diagrams")
    }

    func testWordAndPlainTextKeepTheDiagramSource() throws {
        let service = ConversionService()
        let text = try XCTUnwrap(service.convert(markdown: markdown, to: .plainText).text)
        XCTAssertTrue(text.contains("flowchart LR"), text)

        let word = try service.convert(markdown: markdown, to: .word)
        let inspector = try DocxInspector(data: word.data)
        try inspector.validate()
        XCTAssertTrue(inspector.documentText().contains("flowchart LR"))
    }
}
