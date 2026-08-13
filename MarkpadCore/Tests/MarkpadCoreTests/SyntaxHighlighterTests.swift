import XCTest
@testable import MarkpadCore

final class SyntaxHighlighterTests: XCTestCase {
    private func tokens(_ code: String, _ language: String) -> [(String, SyntaxHighlighter.Token)] {
        let text = code as NSString
        return SyntaxHighlighter.spans(in: code, language: language).map {
            (text.substring(with: $0.range), $0.token)
        }
    }

    func testSwiftKeywordsStringsAndComments() {
        let result = tokens("let x = \"hi\" // note", "swift")
        XCTAssertTrue(result.contains { $0 == ("let", .keyword) }, "\(result)")
        XCTAssertTrue(result.contains { $0 == ("\"hi\"", .string) }, "\(result)")
        XCTAssertTrue(result.contains { $0 == ("// note", .comment) }, "\(result)")
    }

    func testTypeNamesAreHighlightedInSwift() {
        let result = tokens("struct Greeter {}", "swift")
        XCTAssertTrue(result.contains { $0 == ("struct", .keyword) })
        XCTAssertTrue(result.contains { $0 == ("Greeter", .type) }, "\(result)")
    }

    func testNumbersAreHighlighted() {
        let result = tokens("let a = 42", "swift")
        XCTAssertTrue(result.contains { $0 == ("42", .number) }, "\(result)")
    }

    func testBlockCommentSpansLines() {
        let result = tokens("/* one\ntwo */ let a = 1", "swift")
        XCTAssertTrue(result.contains { $0 == ("/* one\ntwo */", .comment) }, "\(result)")
    }

    func testUnterminatedStringStopsAtTheLineEnd() {
        // A stray quote must not swallow the rest of the block.
        let result = tokens("let a = \"oops\nlet b = 1", "swift")
        XCTAssertFalse(result.contains { $0.0.contains("let b") }, "\(result)")
        XCTAssertTrue(result.contains { $0 == ("let", .keyword) })
    }

    func testEscapedQuoteStaysInsideTheString() {
        let result = tokens(#"let a = "say \"hi\"" "#, "swift")
        XCTAssertTrue(result.contains { $0.0 == #""say \"hi\"""# && $0.1 == .string }, "\(result)")
    }

    func testPythonUsesHashComments() {
        let result = tokens("def f(): # comment\n    return None", "python")
        XCTAssertTrue(result.contains { $0 == ("def", .keyword) }, "\(result)")
        XCTAssertTrue(result.contains { $0 == ("# comment", .comment) }, "\(result)")
        XCTAssertTrue(result.contains { $0 == ("None", .keyword) }, "\(result)")
    }

    func testShellAndJSONAreRecognised() {
        XCTAssertTrue(tokens("echo \"hi\" # note", "bash").contains { $0.1 == .comment })
        XCTAssertTrue(tokens("{\"a\": true}", "json").contains { $0 == ("true", .keyword) })
    }

    func testUnknownLanguageProducesNoSpans() {
        XCTAssertTrue(SyntaxHighlighter.spans(in: "some text", language: "brainfuck").isEmpty)
        XCTAssertTrue(SyntaxHighlighter.spans(in: "some text", language: nil).isEmpty)
        XCTAssertFalse(SyntaxHighlighter.supports(language: nil))
    }

    func testOffsetShiftsEveryRange() {
        let spans = SyntaxHighlighter.spans(in: "let a = 1", language: "swift", offset: 100)
        XCTAssertTrue(spans.allSatisfy { $0.range.location >= 100 })
    }

    func testSpansStayInsideTheCodeAndDoNotOverlap() {
        let code = "// c\nlet s = \"str\" /* b */ 12 Type\n"
        let spans = SyntaxHighlighter.spans(in: code, language: "swift")
        let length = (code as NSString).length
        var previousEnd = 0
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.range.location, previousEnd, "spans must not overlap")
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), length)
            previousEnd = NSMaxRange(span.range)
        }
    }

    func testMultiByteCodeKeepsValidRanges() {
        let code = "let greeting = \"日本語 😀\" // コメント"
        let spans = SyntaxHighlighter.spans(in: code, language: "swift")
        let length = (code as NSString).length
        for span in spans {
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), length)
        }
    }
}

final class StyleEngineCodeHighlightingTests: XCTestCase {
    private let engine = StyleEngine()

    func testFencedBlockIsHighlightedButFencesAreNot() {
        let source = "```swift\nlet a = 1\n```\n"
        let layout = engine.layout(for: source)
        let text = source as NSString

        XCTAssertFalse(layout.code.isEmpty, "the block should be highlighted")
        for span in layout.code {
            let snippet = text.substring(with: span.range)
            XCTAssertFalse(snippet.contains("```"), "fences must not be coloured: \(snippet)")
        }
        XCTAssertTrue(layout.code.contains { text.substring(with: $0.range) == "let" })
    }

    func testBlockWithoutALanguageIsNotHighlighted() {
        XCTAssertTrue(engine.layout(for: "```\nlet a = 1\n```\n").code.isEmpty)
    }

    func testHighlightRangesStayInsideTheDocument() throws {
        let source = try Fixtures.sampleMarkdown()
        let length = (source as NSString).length
        for span in engine.layout(for: source).code {
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), length)
        }
    }
}
