import XCTest
@testable import MarkpadCore

final class DelimitedTextImporterTests: XCTestCase {
    private func convert(
        _ data: Data,
        ext: String = "csv",
        options: DocumentImportOptions = .init()
    ) throws -> ImportedMarkdown {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("table.\(ext)")
            try data.write(to: url)
            return try DelimitedTextImporter().convert(url: url, options: options)
        }
    }

    private func convert(_ text: String, ext: String = "csv", options: DocumentImportOptions = .init()) throws -> ImportedMarkdown {
        try convert(Data(text.utf8), ext: ext, options: options)
    }

    func testSimpleTableWithHeader() throws {
        let result = try convert("name,age\nAda,36\nAlan,41\n")
        XCTAssertEqual(result.markdown, """
        | name | age |
        | --- | --- |
        | Ada | 36 |
        | Alan | 41 |

        """)
        XCTAssertEqual(result.notices, [])
        XCTAssertEqual(result.assets, [])
    }

    func testQuotedFieldsWithEscapesDelimitersAndNewlines() throws {
        let csv = "a,b,c\n\"He said \"\"hi\"\"\",\"x, y\",\"line one\nline two\"\n"
        XCTAssertEqual(try convert(csv).markdown, """
        | a | b | c |
        | --- | --- | --- |
        | He said "hi" | x, y | line one line two |

        """)
    }

    func testPipesAndMarkdownInCellsAreEscaped() throws {
        XCTAssertEqual(try convert("h,i\na|b *c*,d\n").markdown, """
        | h | i |
        | --- | --- |
        | a\\|b \\*c\\* | d |

        """)
    }

    func testRaggedRowsArePadded() throws {
        XCTAssertEqual(try convert("a,b,c\n1\n1,2,3,4\n").markdown, """
        | a | b | c |  |
        | --- | --- | --- | --- |
        | 1 |  |  |  |
        | 1 | 2 | 3 | 4 |

        """)
    }

    func testLineEndingsAndTrailingBlankLines() throws {
        let expected = """
        | a | b |
        | --- | --- |
        | 1 | 2 |

        """
        XCTAssertEqual(try convert("a,b\r\n1,2\r\n").markdown, expected)
        XCTAssertEqual(try convert("a,b\r1,2\r").markdown, expected)
        XCTAssertEqual(try convert("a,b\n1,2").markdown, expected)
        XCTAssertEqual(try convert("a,b\n1,2\n\n\n").markdown, expected)
    }

    func testByteOrderMarks() throws {
        let expected = """
        | é | ü |
        | --- | --- |
        | 1 | 2 |

        """
        let text = "é,ü\n1,2\n"
        XCTAssertEqual(try convert(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).markdown, expected)
        XCTAssertEqual(try convert(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!).markdown, expected)
        XCTAssertEqual(try convert(Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!).markdown, expected)
    }

    func testWindows1252Fallback() throws {
        // "café" in Windows-1252: é is 0xE9, which is not valid UTF-8 on its own.
        let data = Data("drink\ncaf".utf8) + Data([0xE9]) + Data("\n".utf8)
        XCTAssertEqual(try convert(data).markdown, """
        | drink |
        | --- |
        | café |

        """)
    }

    func testSemicolonDelimiterIsSniffed() throws {
        XCTAssertEqual(try convert("name;price\nTea;1,50\nCake;3,20\n").markdown, """
        | name | price |
        | --- | --- |
        | Tea | 1,50 |
        | Cake | 3,20 |

        """)
    }

    func testSniffingIgnoresDelimitersInsideQuotes() {
        let text = "\"a,b,c\";\"d\"\n\"e,f\";\"g\"\n"
        XCTAssertEqual(DelimitedTextImporter.sniffDelimiter(in: text), ";")
        XCTAssertEqual(DelimitedTextImporter.sniffDelimiter(in: "one\ntwo\n"), ",")
        XCTAssertEqual(DelimitedTextImporter.sniffDelimiter(in: "a|b\nc|d\n"), "|")
        XCTAssertEqual(DelimitedTextImporter.sniffDelimiter(in: "a\tb\nc\td\n"), "\t")
        // The header must contain the delimiter: a pipe that only appears in data is text.
        XCTAssertEqual(DelimitedTextImporter.sniffDelimiter(in: "name\na|b\n"), ",")
    }

    func testTSVAlwaysSplitsOnTabs() throws {
        XCTAssertEqual(try convert("a,x\tb\n1\t2,3\n", ext: "tsv").markdown, """
        | a,x | b |
        | --- | --- |
        | 1 | 2,3 |

        """)
    }

    func testRowCapKeepsHeaderAndAddsNotice() throws {
        let rows = (1...10).map { "\($0),x" }.joined(separator: "\n")
        let result = try convert("n,v\n" + rows + "\n", options: .init(maximumTableRows: 3))
        XCTAssertEqual(result.markdown, """
        | n | v |
        | --- | --- |
        | 1 | x |
        | 2 | x |
        | 3 | x |

        """)
        XCTAssertEqual(result.notices, ["Only the first 3 rows were kept."])

        let exact = try convert("n\n1\n2\n3\n", options: .init(maximumTableRows: 3))
        XCTAssertEqual(exact.notices, [])
    }

    func testRowCapNoticeUsesGrouping() throws {
        let rows = (1...5_001).map(String.init).joined(separator: "\n")
        let result = try convert("n\n" + rows)
        XCTAssertEqual(result.notices, ["Only the first 5,000 rows were kept."])
        XCTAssertTrue(result.markdown.hasSuffix("| 5000 |\n"))
    }

    func testEmptyFilesHaveNoText() {
        for text in ["", "\n\n", "  \r\n", ",,\n,,\n"] {
            XCTAssertThrowsError(try convert(text), "for \(text.debugDescription)") { error in
                guard case ConversionError.noTextFound = error else {
                    return XCTFail("expected noTextFound, got \(error)")
                }
            }
        }
    }

    func testUnterminatedQuoteKeepsTheRest() throws {
        XCTAssertEqual(try convert("a\n\"open\nstill").markdown, """
        | a |
        | --- |
        | open still |

        """)
    }

    func testCancellation() {
        XCTAssertThrowsError(try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("t.csv")
            try Data("a\n1\n".utf8).write(to: url)
            return try DelimitedTextImporter().convert(url: url, isCancelled: { true })
        }) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
    }
}
