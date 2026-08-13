import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates image and PDF fixtures at run time so the tests carry no binary blobs and the
/// expected content is stated in code next to the assertions.
enum TestImages {
    enum Failure: Error {
        case contextUnavailable
        case encodingFailed
    }

    /// A plain coloured PNG of a known pixel size, used to verify embedding and EMU sizing.
    static func writePNG(to url: URL, width: Int, height: Int) throws {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.contextUnavailable }

        context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw Failure.encodingFailed }
        try write(image, to: url)
    }

    /// Renders lines of text into a PNG so OCR has a realistic, known target.
    static func writeTextPNG(
        to url: URL,
        lines: [String],
        fontSize: CGFloat = 44,
        width: Int = 1000,
        height: Int = 600
    ) throws {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.contextUnavailable }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(lines: lines, in: context, fontSize: fontSize, canvasHeight: CGFloat(height))

        guard let image = context.makeImage() else { throw Failure.encodingFailed }
        try write(image, to: url)
    }

    /// A PDF with a real text layer (drawn with Core Text, not rasterised).
    static func writeTextPDF(
        to url: URL,
        pages: [[PDFLine]],
        pageSize: CGSize = CGSize(width: 612, height: 792)
    ) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw Failure.contextUnavailable
        }
        for page in pages {
            context.beginPDFPage(nil)
            var y = pageSize.height - 72
            for line in page {
                let font = CTFontCreateWithName(
                    (line.bold ? "Helvetica-Bold" : "Helvetica") as CFString,
                    line.fontSize,
                    nil
                )
                let attributed = NSAttributedString(
                    string: line.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                    ]
                )
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(ctLine, context)
                y -= line.fontSize * 1.6
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A PDF page with no text layer — an image of text — to exercise the OCR fallback.
    static func writeScannedPDF(to url: URL, lines: [String], pageSize: CGSize = CGSize(width: 612, height: 792)) throws {
        let scale: CGFloat = 2
        guard let bitmap = CGContext(
            data: nil,
            width: Int(pageSize.width * scale),
            height: Int(pageSize.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.contextUnavailable }

        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: pageSize.width * scale, height: pageSize.height * scale))
        draw(lines: lines, in: bitmap, fontSize: 30 * scale, canvasHeight: pageSize.height * scale)
        guard let image = bitmap.makeImage() else { throw Failure.encodingFailed }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let pdf = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw Failure.contextUnavailable
        }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: mediaBox)
        pdf.endPDFPage()
        pdf.closePDF()
    }

    struct PDFLine {
        let text: String
        let fontSize: CGFloat
        let bold: Bool

        init(_ text: String, fontSize: CGFloat = 12, bold: Bool = false) {
            self.text = text
            self.fontSize = fontSize
            self.bold = bold
        }
    }

    private static func draw(lines: [String], in context: CGContext, fontSize: CGFloat, canvasHeight: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var y = canvasHeight - fontSize * 2
        for line in lines {
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: fontSize, y: y)
            CTLineDraw(ctLine, context)
            y -= fontSize * 1.8
        }
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw Failure.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
    }
}
