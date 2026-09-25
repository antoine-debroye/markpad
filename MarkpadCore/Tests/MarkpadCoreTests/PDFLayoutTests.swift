import CoreText
import Foundation
import XCTest
@testable import MarkpadCore

/// Layout-aware PDF import: running heads in the margins, tables, side-by-side text and
/// paragraph breaks, each found from where text sits on the page. Every case here comes from a
/// real contract pack whose conversion lost them.
final class PDFLayoutTests: XCTestCase {
    /// A run of text placed at a point, baseline-left, in PDF coordinates (origin bottom-left).
    struct Placed {
        let text: String
        let x: CGFloat
        let y: CGFloat
        var size: CGFloat = 11
        var bold = false
    }

    private static let pageSize = CGSize(width: 595, height: 842)

    private func writePDF(_ pages: [[Placed]], to url: URL) throws {
        var box = CGRect(origin: .zero, size: Self.pageSize)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            for item in page {
                let font = CTFontCreateWithName((item.bold ? "Helvetica-Bold" : "Helvetica") as CFString, item.size, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: [
                    .font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                ]))
                context.textPosition = CGPoint(x: item.x, y: item.y)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func convert(_ pages: [[Placed]]) throws -> String {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("layout.pdf")
            try writePDF(pages, to: url)
            return try PDFImporter().convert(url: url)
        }
    }

    /// Lines of body text from `y` downwards at a 14pt pitch.
    private func paragraph(_ lines: [String], x: CGFloat = 56, y: CGFloat) -> [Placed] {
        lines.enumerated().map { Placed(text: $1, x: x, y: y - CGFloat($0) * 14) }
    }

    // MARK: - Running heads

    func testFootersBesidePageNumbersAndPerDocumentHeadersAreRemoved() throws {
        // Two documents in one file: each repeats its own header, but only on its own pages.
        let pages = (1...6).map { index -> [Placed] in
            let header = index <= 4 ? "Partner Agreement — version 1.2" : "Order Form — version 1.1"
            var page = [
                Placed(text: header, x: 56, y: 800, size: 8),
                Placed(text: "Envelope 2df87a3d-f63d", x: 56, y: 30, size: 8),
                Placed(text: "Page \(index) of 6", x: 480, y: 30, size: 8),
            ]
            page += paragraph(["Body text on page \(index) of the pack."], y: 740)
            return page
        }
        let markdown = try convert(pages)
        XCTAssertFalse(markdown.contains("Envelope"), markdown)
        XCTAssertFalse(markdown.contains("Page 3"), markdown)
        XCTAssertFalse(markdown.contains("version 1.2"), markdown)
        XCTAssertFalse(markdown.contains("version 1.1"), "a header on only two pages is still a running head: \(markdown)")
        for index in 1...6 { XCTAssertTrue(markdown.contains("Body text on page \(index) of the pack."), markdown) }
    }

    // MARK: - Tables

    func testPaddedTableWithWrappedCellsBecomesAMarkdownTable() throws {
        // Rows 24pt apart; a wrapped cell line 13pt below its first line.
        let rows: [Placed] = [
            Placed(text: "Sub-processor", x: 56, y: 700), Placed(text: "Purpose", x: 180, y: 700),
            Placed(text: "Data region", x: 380, y: 700),
            Placed(text: "Supabase, Inc.", x: 56, y: 676), Placed(text: "Database, authentication, file", x: 180, y: 676),
            Placed(text: "London, UK (AWS", x: 380, y: 676),
            Placed(text: "storage", x: 180, y: 663), Placed(text: "eu-west-2)", x: 380, y: 663),
            Placed(text: "Vercel Inc.", x: 56, y: 639), Placed(text: "Web hosting", x: 180, y: 639),
            Placed(text: "Dublin, IE", x: 380, y: 639),
        ]
        let markdown = try convert([paragraph(["The sub-processors are listed below."], y: 740) + rows
            + paragraph(["Changes are notified by email."], y: 600)])
        XCTAssertEqual(markdown, """
        The sub-processors are listed below.

        | Sub-processor | Purpose | Data region |
        | --- | --- | --- |
        | Supabase, Inc. | Database, authentication, file storage | London, UK (AWS eu-west-2) |
        | Vercel Inc. | Web hosting | Dublin, IE |

        Changes are notified by email.

        """)
    }

    func testEvenlySpacedTableKeepsEveryRow() throws {
        // No cell wraps, so every gap is the same; each line is its own row.
        let table = [("Data category", "Retention"), ("Employment records", "6 years"),
                     ("Audit logs", "12 months"), ("Payroll", "6 years")]
            .enumerated().flatMap { index, row in
                [Placed(text: row.0, x: 56, y: 700 - CGFloat(index) * 20), Placed(text: row.1, x: 260, y: 700 - CGFloat(index) * 20)]
            }
        let markdown = try convert([table])
        XCTAssertEqual(markdown, """
        | Data category | Retention |
        | --- | --- |
        | Employment records | 6 years |
        | Audit logs | 12 months |
        | Payroll | 6 years |

        """)
    }

    func testCloseColumnsAreFoundFromTheCellsBelowTheHeader() throws {
        // "Acknowledge" and "Initial" are closer than the gap that splits a header row.
        var items: [Placed] = [
            Placed(text: "Priority", x: 56, y: 700), Placed(text: "Acknowledge", x: 200, y: 700),
            Placed(text: "Initial", x: 272, y: 700), Placed(text: "Resolution", x: 400, y: 700),
        ]
        for (index, row) in [("P1", "4 hours", "4 hours", "1 day"), ("P2", "1 day", "2 days", "3 days")].enumerated() {
            let y = 676 - CGFloat(index) * 24
            items += [Placed(text: row.0, x: 56, y: y), Placed(text: row.1, x: 200, y: y),
                      Placed(text: row.2, x: 272, y: y), Placed(text: row.3, x: 400, y: y)]
        }
        let markdown = try convert([items])
        XCTAssertTrue(markdown.contains("| Priority | Acknowledge | Initial | Resolution |"), markdown)
        XCTAssertTrue(markdown.contains("| P1 | 4 hours | 4 hours | 1 day |"), markdown)
    }

    func testTableContinuedOnTheNextPageIsOneTable() throws {
        func row(_ term: String, _ meaning: String, _ y: CGFloat) -> [Placed] {
            [Placed(text: term, x: 56, y: y), Placed(text: meaning, x: 180, y: y)]
        }
        let pages = [
            row("Platform", "the software", 700) + row("DPA", "the data agreement", 676),
            row("SLA", "the service levels", 760) + row("Order Form", "the commercial terms", 736),
        ]
        let markdown = try convert(pages)
        XCTAssertEqual(markdown, """
        | Platform | the software |
        | --- | --- |
        | DPA | the data agreement |
        | SLA | the service levels |
        | Order Form | the commercial terms |

        """)
    }

    // MARK: - Paragraphs and headings

    func testShortLinesStaySeparateAndWrappedLinesJoin() throws {
        let cover = [
            Placed(text: "Jamie Technologies Ltd · Company No. 17325258", x: 56, y: 760, size: 9),
            Placed(text: "Version 1.2 | July 2026 | Confidential", x: 56, y: 748, size: 9),
        ]
        let body = paragraph([
            "This document sets out the commercial and legal terms under which the Platform is",
            "made available to channel partners, whether under its own branding or white label.",
        ], y: 720)
        let markdown = try convert([cover + body])
        XCTAssertEqual(markdown, """
        Jamie Technologies Ltd · Company No. 17325258

        Version 1.2 | July 2026 | Confidential

        This document sets out the commercial and legal terms under which the Platform is made available to channel partners, whether under its own branding or white label.

        """)
    }

    func testHeadingWrappedOntoTwoLinesIsOneHeading() throws {
        let items = [
            Placed(text: "JAMIE HR PARTNER DATA PROCESSING", x: 56, y: 760, size: 19),
            Placed(text: "AGREEMENT", x: 56, y: 737, size: 19),
        ] + paragraph([
            "This agreement governs the processing of personal data by the processor on",
            "behalf of the partner as controller in connection with the Platform.",
            "It forms part of the principal agreement between the parties to it.",
        ], y: 700)
        let markdown = try convert([items])
        XCTAssertTrue(markdown.hasPrefix("# JAMIE HR PARTNER DATA PROCESSING AGREEMENT\n\n"), markdown)
    }

    func testSentenceRunningOverAPageBreakStaysOneParagraph() throws {
        let pages = [
            paragraph(["Each party may approve any content that features its own name before"], y: 120),
            paragraph(["it is published."], y: 760),
        ]
        let markdown = try convert(pages)
        XCTAssertEqual(markdown, "Each party may approve any content that features its own name before it is published.\n")
    }

    // MARK: - Side by side

    func testTwoColumnPageReadsOneColumnThenTheOther() throws {
        let left = (0..<10).map { Placed(text: "Left column line \($0) runs across the column", x: 56, y: 760 - CGFloat($0) * 14) }
        let right = (0..<10).map { Placed(text: "Right column line \($0) runs across the colum", x: 310, y: 760 - CGFloat($0) * 14) }
        let markdown = try convert([left + right])
        let leftEnd = try XCTUnwrap(markdown.range(of: "Left column line 9"))
        let rightStart = try XCTUnwrap(markdown.range(of: "Right column line 0"))
        XCTAssertLessThan(leftEnd.lowerBound, rightStart.lowerBound, "the left column is read in full first: \(markdown)")
        XCTAssertFalse(markdown.contains("|"), "a two-column page is not a table: \(markdown)")
    }

    func testOneRowOfSideBySideTextIsSplitNotTabled() throws {
        let items = paragraph(["A paragraph of ordinary text sits above the line with two parts."], y: 760)
            + [Placed(text: "Prepared by Legal", x: 56, y: 700), Placed(text: "Approved 02/09/2026", x: 420, y: 700)]
            + paragraph(["Another paragraph of ordinary text follows it on the page here."], y: 660)
        let markdown = try convert([items])
        XCTAssertTrue(markdown.contains("\n\nPrepared by Legal\n\nApproved 02/09/2026\n\n"), markdown)
        XCTAssertFalse(markdown.contains("|"), markdown)
    }
}
