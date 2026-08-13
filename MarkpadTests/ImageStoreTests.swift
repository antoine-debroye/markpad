import AppKit
import XCTest
@testable import Markpad

final class ImageStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markpad-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @discardableResult
    private func writeImage(named name: String, width: Int = 400, height: Int = 200) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()

        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url
    }

    /// Waits for the store's asynchronous load to finish.
    private func load(_ store: ImageStore, source: String) {
        let loaded = expectation(description: "image loaded")
        loaded.assertForOverFulfill = false
        store.onLoad = { loaded.fulfill() }
        store.prepare(source)
        wait(for: [loaded], timeout: 5)
    }

    func testLoadsAnImageRelativeToTheDocument() throws {
        try writeImage(named: "photo.png")
        let store = ImageStore()
        store.documentDirectory = directory

        load(store, source: "photo.png")
        let entry = store.entry(for: "photo.png", availableWidth: 600)
        XCTAssertNotNil(entry, "a sibling image should load")
        XCTAssertEqual(entry?.image.size.width, 400)
    }

    func testWideImageIsScaledToTheAvailableWidth() throws {
        try writeImage(named: "wide.png", width: 1200, height: 600)
        let store = ImageStore()
        store.documentDirectory = directory

        load(store, source: "wide.png")
        let entry = try XCTUnwrap(store.entry(for: "wide.png", availableWidth: 500))
        XCTAssertEqual(entry.displaySize.width, 500, accuracy: 0.5)
        XCTAssertEqual(entry.displaySize.height, 250, accuracy: 0.5, "aspect ratio must hold")
    }

    func testTallImageIsCappedInHeight() throws {
        try writeImage(named: "tall.png", width: 200, height: 2000)
        let store = ImageStore()
        store.documentDirectory = directory

        load(store, source: "tall.png")
        let entry = try XCTUnwrap(store.entry(for: "tall.png", availableWidth: 600))
        XCTAssertLessThanOrEqual(entry.displaySize.height, 420)
    }

    func testPercentEncodedNameResolves() throws {
        try writeImage(named: "my photo.png")
        let store = ImageStore()
        store.documentDirectory = directory

        load(store, source: "my%20photo.png")
        XCTAssertNotNil(store.entry(for: "my%20photo.png", availableWidth: 600))
    }

    func testSubdirectoryPathResolves() throws {
        let nested = directory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 50, height: 50))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 50, height: 50).fill(); image.unlockFocus()
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            .write(to: nested.appendingPathComponent("icon.png"))

        let store = ImageStore()
        store.documentDirectory = directory
        load(store, source: "assets/icon.png")
        XCTAssertNotNil(store.entry(for: "assets/icon.png", availableWidth: 600))
    }

    func testMissingImageIsReportedAsFailedRatherThanPending() throws {
        let store = ImageStore()
        store.documentDirectory = directory
        load(store, source: "absent.png")

        XCTAssertNil(store.entry(for: "absent.png", availableWidth: 600))
        XCTAssertTrue(store.hasFailed("absent.png"), "a missing file must not stay pending forever")
    }

    func testRemoteSourcesAreNotFetched() {
        let store = ImageStore()
        store.documentDirectory = directory
        store.prepare("https://example.com/a.png")
        XCTAssertNil(store.entry(for: "https://example.com/a.png", availableWidth: 600))
    }

    /// Without a document folder there is nothing to resolve a relative path against, which
    /// is the state an unsaved document is in.
    func testRelativePathWithoutADocumentFolderDoesNotResolve() {
        let store = ImageStore()
        store.documentDirectory = nil
        store.prepare("photo.png")
        XCTAssertNil(store.entry(for: "photo.png", availableWidth: 600))
    }

    func testUnusedImagesAreDroppedFromTheCache() throws {
        try writeImage(named: "keep.png")
        try writeImage(named: "drop.png")
        let store = ImageStore()
        store.documentDirectory = directory

        load(store, source: "keep.png")
        load(store, source: "drop.png")
        XCTAssertNotNil(store.entry(for: "drop.png", availableWidth: 600))

        store.retain(sources: ["keep.png"])
        XCTAssertNotNil(store.entry(for: "keep.png", availableWidth: 600))
        XCTAssertNil(store.entry(for: "drop.png", availableWidth: 600), "unreferenced images should be released")
    }
}
