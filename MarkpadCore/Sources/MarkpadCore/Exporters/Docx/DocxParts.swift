import Foundation

/// Static and generated XML parts of a `.docx` package.
enum DocxParts {
    static let mainNamespaces = """
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
    """

    /// Content width of a US Letter page with 1" margins, in twips. Table grids are sized
    /// against this so columns fill the text column exactly.
    static let contentWidthTwips = 9360

    static func contentTypes(imageExtensions: Set<String>) -> String {
        var defaults = [
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>",
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        ]
        for ext in imageExtensions.sorted() {
            guard let mime = imageMIMEType(forExtension: ext) else { continue }
            defaults.append("<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>")
        }
        let office = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        return """
        \(XML.declaration)
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        \(defaults.joined())\
        <Override PartName="/word/document.xml" ContentType="\(office).document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="\(office).styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="\(office).numbering+xml"/>\
        </Types>
        """
    }

    static func imageMIMEType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return nil
        }
    }

    static let packageRelationships = """
    \(XML.declaration)
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" \
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
    Target="word/document.xml"/>\
    </Relationships>
    """

    static func documentRelationships(_ relationships: [DocxRelationship]) -> String {
        let entries = relationships.map { relationship -> String in
            let external = relationship.isExternal ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"\(relationship.id)\" Type=\"\(relationship.kind.type)\" " +
                "Target=\"\(XML.escape(relationship.target))\"\(external)/>"
        }
        return """
        \(XML.declaration)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(entries.joined())</Relationships>
        """
    }

    /// Heading point sizes for levels 1...6, expressed in half-points as Word expects.
    private static let headingHalfPoints = [40, 32, 26, 24, 22, 22]

    static func styles(theme: MarkdownTheme) -> String {
        let headingColor = theme.light.heading.replacingOccurrences(of: "#", with: "").uppercased()
        let quoteColor = theme.light.quoteText.replacingOccurrences(of: "#", with: "").uppercased()
        let codeShade = theme.light.codeBackground.replacingOccurrences(of: "#", with: "").uppercased()

        var headings = ""
        for level in 1...6 {
            let size = headingHalfPoints[level - 1]
            let italic = level == 6 ? "<w:i/>" : ""
            headings += """
            <w:style w:type="paragraph" w:styleId="Heading\(level)">\
            <w:name w:val="heading \(level)"/><w:basedOn w:val="Normal"/><w:qFormat/>\
            <w:pPr><w:keepNext/><w:spacing w:before="\(level <= 2 ? 320 : 240)" w:after="120"/>\
            <w:outlineLvl w:val="\(level - 1)"/></w:pPr>\
            <w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi"/><w:b/>\(italic)\
            <w:color w:val="\(headingColor)"/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>\
            </w:style>
            """
        }

        return """
        \(XML.declaration)
        <w:styles \(mainNamespaces)>\
        <w:docDefaults><w:rPrDefault><w:rPr>\
        <w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:cs="Helvetica Neue"/>\
        <w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
        </w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
        \(headings)\
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:ind w:left="480"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="12" w:color="C7C7CC"/></w:pBdr>\
        </w:pPr><w:rPr><w:i/><w:color w:val="\(quoteColor)"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="SourceCode"><w:name w:val="Source Code"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:contextualSpacing/>\
        <w:shd w:val="clear" w:color="auto" w:fill="\(codeShade)"/><w:ind w:left="240" w:right="240"/></w:pPr>\
        <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="19"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>\
        <w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/><w:contextualSpacing/></w:pPr></w:style>\
        <w:style w:type="character" w:styleId="InlineCode"><w:name w:val="Inline Code"/>\
        <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="19"/>\
        <w:shd w:val="clear" w:color="auto" w:fill="\(codeShade)"/></w:rPr></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>\
        <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/>\
        <w:tblPr><w:tblBorders>\
        <w:top w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/>\
        <w:left w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/>\
        <w:right w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/>\
        <w:insideV w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/>\
        </w:tblBorders></w:tblPr></w:style>\
        </w:styles>
        """
    }

    /// Builds `numbering.xml`.
    ///
    /// Bullets share a single numbering instance, while every ordered list gets its own
    /// `w:num` with a `startOverride` so consecutive lists restart instead of continuing.
    static func numbering(orderedListStarts: [Int]) -> String {
        var abstract = "<w:abstractNum w:abstractNumId=\"0\">"
        for level in 0..<9 {
            let indent = 360 * (level + 1) + 360
            abstract += """
            <w:lvl w:ilvl="\(level)"><w:start w:val="1"/><w:numFmt w:val="bullet"/>\
            <w:lvlText w:val="\(level % 3 == 0 ? "•" : (level % 3 == 1 ? "◦" : "▪"))"/><w:lvlJc w:val="left"/>\
            <w:pPr><w:ind w:left="\(indent)" w:hanging="360"/></w:pPr>\
            <w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:hint="default"/></w:rPr></w:lvl>
            """
        }
        abstract += "</w:abstractNum><w:abstractNum w:abstractNumId=\"1\">"
        for level in 0..<9 {
            let indent = 360 * (level + 1) + 360
            let format = ["decimal", "lowerLetter", "lowerRoman"][level % 3]
            abstract += """
            <w:lvl w:ilvl="\(level)"><w:start w:val="1"/><w:numFmt w:val="\(format)"/>\
            <w:lvlText w:val="%\(level + 1)."/><w:lvlJc w:val="left"/>\
            <w:pPr><w:ind w:left="\(indent)" w:hanging="360"/></w:pPr></w:lvl>
            """
        }
        abstract += "</w:abstractNum>"

        // numId 1 is the shared bullet instance; ordered lists start at numId 2.
        var instances = "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        for (index, start) in orderedListStarts.enumerated() {
            let numId = index + 2
            var overrides = ""
            for level in 0..<9 {
                let value = level == 0 ? start : 1
                overrides += "<w:lvlOverride w:ilvl=\"\(level)\"><w:startOverride w:val=\"\(value)\"/></w:lvlOverride>"
            }
            instances += "<w:num w:numId=\"\(numId)\"><w:abstractNumId w:val=\"1\"/>\(overrides)</w:num>"
        }

        return """
        \(XML.declaration)
        <w:numbering \(mainNamespaces)>\(abstract)\(instances)</w:numbering>
        """
    }

    static let sectionProperties = """
    <w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
    <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>\
    </w:sectPr>
    """
}
