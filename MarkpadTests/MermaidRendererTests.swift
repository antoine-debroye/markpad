import AppKit
import XCTest
@testable import Markpad
@testable import MarkpadCore

/// Exercises the real renderer: a hidden web view running the bundled Mermaid build.
///
/// These tests are the reason the library is bundled rather than fetched — they run with no
/// network, and so does the app.
@MainActor
final class MermaidRendererTests: XCTestCase {
    private let flowchart = "flowchart LR\n  A[Start] --> B[Finish]\n"

    func testBundledResourcesArePresent() {
        let host = Bundle.main.url(forResource: "mermaid-host", withExtension: "html", subdirectory: "Mermaid")
            ?? Bundle.main.url(forResource: "mermaid-host", withExtension: "html")
        XCTAssertNotNil(host, "the renderer's host page must ship in the app bundle")

        let library = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid")
            ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
        XCTAssertNotNil(library, "mermaid.min.js must ship alongside it")
    }

    func testRendersADiagramToSVGAndAPicture() async throws {
        let rendered = await MermaidRenderer.shared.diagramRenderingIfNeeded(flowchart, dark: false)
        let diagram = try XCTUnwrap(rendered, "the flowchart should render")

        XCTAssertTrue(diagram.svg.contains("<svg"), String(diagram.svg.prefix(200)))
        XCTAssertTrue(diagram.svg.contains("Start"), "node labels should survive into the SVG")
        XCTAssertGreaterThan(diagram.size.width, 0)
        XCTAssertGreaterThan(diagram.size.height, 0)
        XCTAssertGreaterThan(diagram.image.size.width, 0)
    }

    func testInvalidDiagramFailsInsteadOfHanging() async {
        let result = await MermaidRenderer.shared
            .diagramRenderingIfNeeded("this is not a diagram {{{{", dark: false)
        XCTAssertNil(result, "a diagram that cannot be parsed must not produce a picture")
    }

    func testSecondRenderIsServedFromTheCache() async throws {
        _ = await MermaidRenderer.shared.diagramRenderingIfNeeded(flowchart, dark: false)
        // A cached diagram is available synchronously, which is what keeps scrolling smooth.
        XCTAssertNotNil(MermaidRenderer.shared.diagram(for: flowchart, dark: false))
    }

    func testLightAndDarkAreRenderedSeparately() async throws {
        let lightRender = await MermaidRenderer.shared.diagramRenderingIfNeeded(flowchart, dark: false)
        let darkRender = await MermaidRenderer.shared.diagramRenderingIfNeeded(flowchart, dark: true)
        let light = try XCTUnwrap(lightRender)
        let dark = try XCTUnwrap(darkRender)
        XCTAssertNotEqual(light.svg, dark.svg, "the two appearances should not share one rendering")
    }

    /// Diagrams render one at a time because they share a web view; overlapping renders used
    /// to return whichever diagram happened to be on the page last.
    func testConcurrentDiagramsEachReturnTheirOwnPicture() async throws {
        let first = "flowchart LR\n  Alpha --> Beta\n"
        let second = "flowchart LR\n  Gamma --> Delta\n"

        async let a = MermaidRenderer.shared.diagramRenderingIfNeeded(first, dark: false)
        async let b = MermaidRenderer.shared.diagramRenderingIfNeeded(second, dark: false)
        let (one, two) = await (a, b)

        let svgOne = try XCTUnwrap(one?.svg)
        let svgTwo = try XCTUnwrap(two?.svg)
        XCTAssertTrue(svgOne.contains("Alpha"), "first diagram lost its own content")
        XCTAssertTrue(svgTwo.contains("Gamma"), "second diagram lost its own content")
        XCTAssertFalse(svgOne.contains("Gamma"), "diagrams must not bleed into each other")
    }

    func testExportCollectsEveryDiagramInADocument() async throws {
        let markdown = """
        # Doc

        ```mermaid
        flowchart LR
          One --> Two
        ```

        Text between.

        ```mermaid
        flowchart TD
          Three --> Four
        ```
        """

        let rendered = await DocumentActions.renderedDiagrams(in: markdown)
        XCTAssertEqual(rendered.count, 2)
        XCTAssertTrue(rendered.values.allSatisfy { $0.contains("<svg") })

        var service = ConversionService()
        service.diagrams = rendered
        let html = try XCTUnwrap(service.convert(markdown: markdown, to: .html).text)

        XCTAssertEqual(html.components(separatedBy: "<figure class=\"diagram\">").count - 1, 2)
        XCTAssertFalse(html.contains("language-mermaid"), "diagrams should not also appear as code")
        XCTAssertTrue(html.contains("One"), html.prefix(400).description)
    }
}
