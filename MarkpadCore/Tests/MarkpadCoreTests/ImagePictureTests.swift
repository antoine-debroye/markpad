import Foundation
import ImageIO
import XCTest
@testable import MarkpadCore

/// Converting an image with or without the picture itself.
final class ImagePictureTests: XCTestCase {
    private func importImage(_ url: URL, picture: Bool, folder: String? = "photo_assets") async throws -> ImportedMarkdown {
        var options = ImportOptions()
        options.document.assetFolderName = folder
        options.document.includesOriginalPicture = picture
        return try await ConversionService().importDocument(at: url, options: options)
    }

    func testPictureAboveItsText() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("Slide photo.png")
            try TestImages.writeTextPNG(to: url, lines: ["Working with Universal"])
            let result = try await importImage(url, picture: true)
            XCTAssertTrue(result.markdown.hasPrefix("![Slide photo](photo_assets/Slide-photo.png)\n\n"), result.markdown)
            XCTAssertTrue(result.markdown.lowercased().contains("working with universal"), result.markdown)
            XCTAssertEqual(result.assets.map(\.name), ["Slide-photo.png"])
            XCTAssertEqual(result.assets.first?.data, try Data(contentsOf: url), "the original file, untouched")
        }
    }

    func testTextOnly() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("slide.png")
            try TestImages.writeTextPNG(to: url, lines: ["Working with Universal"])
            let result = try await importImage(url, picture: false)
            XCTAssertFalse(result.markdown.contains("!["), result.markdown)
            XCTAssertTrue(result.assets.isEmpty)
        }
    }

    func testPhotoWithoutTextConvertsOnlyWhenThePictureIsKept() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("blank.png")
            try TestImages.writePNG(to: url, width: 300, height: 200)
            let result = try await importImage(url, picture: true)
            XCTAssertEqual(result.markdown, "![blank](photo_assets/blank.png)\n")
            do {
                _ = try await importImage(url, picture: false)
                XCTFail("text only, and there is no text")
            } catch ConversionError.noTextFound {}
        }
    }

    func testNoFolderMeansNoPicture() async throws {
        // A Shortcuts action returning one Markdown file has nowhere to keep the picture.
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("slide.png")
            try TestImages.writeTextPNG(to: url, lines: ["Working with Universal"])
            let result = try await importImage(url, picture: true, folder: nil)
            XCTAssertFalse(result.markdown.contains("!["), result.markdown)
        }
    }

    func testWordExportEmbedsThePicture() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("slide.png")
            try TestImages.writeTextPNG(to: url, lines: ["Working with Universal"])
            var options = ImportOptions()
            options.document.includesOriginalPicture = true
            let result = try ConversionService().convert(fileAt: url, to: .word, options: options)
            let reader = try ZipReader(data: result.data)
            XCTAssertTrue(reader.entries.contains { $0.name.hasPrefix("word/media/") }, reader.entries.map(\.name).description)
        }
    }

    func testIPhonePhotosAreSavedAsUprightJPEG() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            // Build a HEIC tagged as rotated, as an iPhone portrait photo is.
            let png = directory.appendingPathComponent("source.png")
            try TestImages.writeTextPNG(to: png, lines: ["Working with Universal"])
            let heic = directory.appendingPathComponent("IMG_0001.HEIC")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
            guard let destination = CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil) else {
                throw XCTSkip("This Mac cannot encode HEIC")
            }
            CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw XCTSkip("This Mac cannot encode HEIC") }

            let result = try await importImage(heic, picture: true)
            XCTAssertTrue(result.markdown.hasPrefix("![IMG\\_0001](photo_assets/IMG_0001.jpg)"), result.markdown)
            let data = try XCTUnwrap(result.assets.first?.data)
            XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG")
            let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil) as? [CFString: Any]
            XCTAssertEqual(properties?[kCGImagePropertyOrientation] as? Int, 6, "orientation kept")
        }
    }
}
