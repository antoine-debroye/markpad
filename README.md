# Markpad

A native macOS Markdown editor and conversion hub. Swift and AppKit throughout — no Electron, no web view in the editor.

- **Typora-style editing.** One pane. Markdown renders as you type; the block your caret is in reveals its raw syntax and re-renders when you leave it.
- **Convert anything.** Markdown → Word (`.docx`), HTML, plain text. PDF → Markdown. Images → Markdown via on-device text recognition.
- **One click from anywhere.** Shortcuts actions for every conversion, so a Finder Quick Action or a hotkey does the whole job.
- **Quick Look.** Press Space on a `.md` file in the Finder and see it formatted.
- **Light, Dark or Automatic**, applied to the editor, previews and exported HTML alike.

## Building

Requires Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./scripts/build.sh
```

The generated `Markpad.xcodeproj` is not checked in — `project.yml` is the source of truth, so regenerate it after changing targets or settings.

To run the app from the Finder, and to make Quick Look and Shortcuts pick it up reliably, install it:

```bash
./scripts/build.sh release && cp -R dist/Markpad.app /Applications/
```

## Testing

```bash
./scripts/test.sh
```

Two suites run: the conversion engine (`swift test` in `MarkpadCore`) and the editor (`xcodebuild test`).

Generated `.docx` files are checked against readers that did not produce them — `/usr/bin/unzip`, Cocoa's Office importer and `textutil` — because a package that only round-trips through its own writer can hide format bugs that make Word offer to "repair" the file.

## How it is put together

```
MarkpadCore/      Conversion engine and editor logic. No AppKit, so it tests on its own.
  Exporters/      HTML, plain text, and a direct OOXML .docx writer
  Importers/      PDF (PDFKit) and image (Vision) to Markdown
  Editor/         StyleEngine: Markdown source → styled runs and syntax markers
Markpad/          The app: document shell, editor, Shortcuts actions, menus
MarkpadQuickLook/ Quick Look preview extension
```

### The editor

The text storage always holds the raw Markdown source, unchanged. Rendering comes from two things applied on top of it:

1. **Text attributes** for fonts, colours and paragraph layout.
2. **Glyph suppression** — syntax markers are collapsed to zero width by the layout manager rather than deleted.

Because the text is never rewritten, saving, undo, find and copy all operate on exactly what the author typed, and there is no source map to fall out of sync. When the caret enters a block, that block's markers regain their width; when it leaves, they collapse again.

Two details that are easy to get wrong and are covered by tests:

- **Offsets.** cmark reports positions as UTF-8 byte columns while `NSTextStorage` counts UTF-16 units. Every document containing an emoji, an accent or CJK text puts the two out of step, so all conversion goes through `SourceIndex`.
- **Quick Look and untrusted files.** Markdown permits inline HTML, and exports pass it through. Previews do not: Quick Look renders files the user merely selected in the Finder, so embedded markup is escaped rather than executed.

### Dependencies

Only [swift-markdown](https://github.com/swiftlang/swift-markdown). The `.docx` writer emits OOXML directly and packages it with a small built-in ZIP writer, which keeps the app free of a third-party archiver and its signing and notarization overhead.

## Shortcuts

Three actions appear once the app has been launched at least once:

| Action | Input | Output |
| --- | --- | --- |
| Convert Files with Markpad | Markdown, PDF or image files | Files in the chosen format |
| Get Markdown from File with Markpad | PDF, image or Markdown | Markdown text |
| Convert Markdown Text with Markpad | Markdown text | A file in the chosen format |

They run without bringing the app to the front, and return files rather than writing next to the input, so Shortcuts' own "Save File" step decides where output lands.

If the actions do not appear, copy the app to `/Applications`, launch it once, then restart Shortcuts.

## Quick Look

If a `.md` file still previews as plain text after installing, enable Markpad under **System Settings ▸ General ▸ Login Items & Extensions ▸ Quick Look**, and run `qlmanage -r` to clear the cache. Another installed app may also claim Markdown previews; the same panel decides which one wins.

## Distributing

`scripts/build.sh` signs ad-hoc so the project builds on any Mac without a developer account. To share the app with other people:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/notarize.sh
```

This needs a paid Apple Developer account: a Developer ID certificate in your keychain and a `notarytool` credential profile. The script's header lists the one-off setup commands.

## Known limits

- Tables render as aligned monospaced source rather than a drawn grid.
- Images show their Markdown syntax instead of the picture; they are embedded properly in HTML and Word exports.
- PDF extraction targets single-column documents. Multi-column layouts, footnotes and complex tables are best effort.
- Code blocks are not syntax-highlighted by language.
