import XCTest
@testable import MarkpadCore

final class StructuredTextImporterTests: XCTestCase {
    private func convert(_ data: Data, ext: String) throws -> ImportedMarkdown {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.\(ext)")
            try data.write(to: url)
            return try StructuredTextImporter().convert(url: url)
        }
    }

    private func convert(_ text: String, ext: String) throws -> ImportedMarkdown {
        try convert(Data(text.utf8), ext: ext)
    }

    // MARK: JSON

    func testJSONKeepsOriginalTextKeyOrderAndBigNumbers() throws {
        let json = """
        {
          "zebra": 1,
          "apple": 123456789012345678901234567890,
          "tiny": 1e999,
          "nested": {"b": [true, false, null], "a": "x"}
        }

        """
        let result = try convert(json, ext: "json")
        XCTAssertEqual(result.markdown, """
        ```json
        {
          "zebra": 1,
          "apple": 123456789012345678901234567890,
          "tiny": 1e999,
          "nested": {"b": [true, false, null], "a": "x"}
        }
        ```

        """)
        XCTAssertEqual(result.notices, [])
    }

    func testJSONFenceGrowsPastBackticksInStrings() throws {
        let result = try convert(#"{"code": "````swift"}"#, ext: "json")
        XCTAssertEqual(result.markdown, """
        `````json
        {"code": "````swift"}
        `````

        """)
    }

    func testJSONWithByteOrderMarks() throws {
        let text = #"{"é": 1}"#
        let expected = "```json\n{\"é\": 1}\n```\n"
        XCTAssertEqual(try convert(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8), ext: "json").markdown, expected)
        XCTAssertEqual(try convert(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!, ext: "json").markdown, expected)
        XCTAssertEqual(try convert(Data([0x00, 0x00, 0xFE, 0xFF]) + text.data(using: .utf32BigEndian)!, ext: "json").markdown, expected)
    }

    func testInvalidJSONIsShownAsPlainText() throws {
        let result = try convert("{\"a\": 1,}", ext: "json")
        XCTAssertEqual(result.markdown, "```\n{\"a\": 1,}\n```\n")
        XCTAssertEqual(result.notices, ["The file is not valid JSON; it is shown as plain text."])
    }

    func testJSONSyntaxChecker() {
        let valid = ["0", "-0.5e+10", "\"a\\u00e9\\n\"", "[]", "{}", " [1, [2, {\"a\": []}]] ", "null", "1E5"]
        for text in valid {
            XCTAssertTrue(StructuredTextJSONSyntax.isValid(text), text)
        }
        let invalid = ["", "[1,]", "{\"a\":1,}", "[01]", "{'a':1}", "[NaN]", "\"\\x\"", "[1] [2]",
                       "{\"a\" 1}", "[", "\"open", "tru", "1.", "-", "{1: 2}", "\"tab\there\""]
        for text in invalid {
            XCTAssertFalse(StructuredTextJSONSyntax.isValid(text), text)
        }
        // Deep nesting is checked without recursion.
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        XCTAssertTrue(StructuredTextJSONSyntax.isValid(deep))
    }

    func testEmptyJSONHasNoText() {
        XCTAssertThrowsError(try convert(" \n\n", ext: "json")) { error in
            guard case ConversionError.noTextFound = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: XML

    func testWellFormedXMLIsFenced() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <root b="2" a="1">
          <item>Fish &amp; chips</item>
        </root>
        """
        let result = try convert(xml, ext: "xml")
        XCTAssertEqual(result.markdown, "```xml\n" + xml + "\n```\n")
        XCTAssertEqual(result.notices, [])
    }

    func testMalformedXMLIsShownAsPlainText() throws {
        let result = try convert("<a><b></a>", ext: "xml")
        XCTAssertEqual(result.markdown, "```\n<a><b></a>\n```\n")
        XCTAssertEqual(result.notices, ["The file is not well-formed XML; it is shown as plain text."])
    }

    func testXMLDeclaredEncodingIsHonoured() throws {
        var data = Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n<a>caf".utf8)
        data.append(0xE9)
        data.append(contentsOf: Array("</a>".utf8))
        let result = try convert(data, ext: "xml")
        XCTAssertEqual(result.markdown, "```xml\n<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n<a>café</a>\n```\n")
    }
}
