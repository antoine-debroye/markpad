import Foundation

/// Converts PowerPoint presentations into Markdown.
///
/// Each slide becomes a `<!-- Slide N -->` marker, its title a level-2 heading, its text boxes
/// paragraphs or list items in the order they are stacked on the slide, tables GFM tables and
/// pictures image links. Speaker notes follow under a "Notes" heading. Hidden slides are
/// included — they are still part of the deck's content. Charts and SmartArt have no faithful
/// Markdown form and are left out with a notice.
public struct PresentationImporter: Sendable {
    public init() {}

    public func convert(
        url: URL,
        options: DocumentImportOptions = .init(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ImportedMarkdown {
        do {
            return try importPresentation(url: url, options: options, progress: progress, isCancelled: isCancelled)
        } catch {
            throw OfficeImportPackage.conversionError(for: error, url: url)
        }
    }

    private func importPresentation(
        url: URL,
        options: DocumentImportOptions,
        progress: ImportProgress.Handler?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ImportedMarkdown {
        let zip = try OfficeImportPackage.open(url)
        let presentationPart = try OfficeImportPackage.mainPart(in: zip, fallback: "ppt/presentation.xml")
        guard let presentation = try OfficeImportPackage.element(presentationPart, in: zip, url: url),
              presentation.name == "presentation" else {
            throw ConversionError.unreadableFile(url)
        }
        let relationships = try OfficeImportRelationships.load(for: presentationPart, in: zip)

        // The deck's order is the order of `p:sldIdLst`, not the numbering of the slide parts.
        let slideParts: [String] = (presentation.child("sldIdLst")?.children("sldId") ?? []).compactMap { slideID in
            guard let id = slideID.relationshipAttribute("id"),
                  let relationship = relationships[id], relationship.hasType("slide") else { return nil }
            return relationships.partPath(for: relationship)
        }

        var reporter = ImportReporter(totalUnits: max(slideParts.count, 1), handler: progress, isCancelled: isCancelled)
        reporter.unitKind = .slide
        reporter.report(.reading, index: 0)

        let reader = PresentationSlideReader(zip: zip, collector: AssetCollector(folderName: options.assetFolderName))
        var blocks: [MarkdownBlock] = []
        var foundContent = false
        var unreadableSlides: [Int] = []

        for (index, part) in slideParts.enumerated() {
            try reporter.checkCancellation()
            reporter.report(.extractingText, index: index)
            try autoreleasepool {
                blocks.append(.raw("<!-- Slide \(index + 1) -->"))
                guard let slide = try reader.slide(at: part) else {
                    unreadableSlides.append(index + 1)
                    return
                }
                if slide.contains(where: PresentationSlideReader.hasContent) { foundContent = true }
                blocks += slide
            }
        }

        try reporter.checkCancellation()
        reporter.reportAssembling()
        guard foundContent else { throw ConversionError.noTextFound(url) }

        var notices: [String] = []
        if !unreadableSlides.isEmpty {
            let list = unreadableSlides.map(String.init).joined(separator: ", ")
            notices.append(unreadableSlides.count == 1
                ? "Slide \(list) couldn't be read and was left out."
                : "Slides \(list) couldn't be read and were left out.")
        }
        if reader.omittedGraphics { notices.append("Charts and SmartArt were left out.") }

        let markdown = MarkdownRenderer.render(blocks)
        reporter.reportFinished()
        return ImportedMarkdown(markdown: markdown, assets: reader.collector.assets, notices: notices)
    }
}
