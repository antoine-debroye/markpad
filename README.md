# Markpad

**A native Markdown editor for macOS that shows you the document, not the syntax.**

[![Latest release](https://img.shields.io/github/v/release/antoine-debroye/markpad?label=download&color=blue)](https://github.com/antoine-debroye/markpad/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)](https://github.com/antoine-debroye/markpad/releases/latest)
[![Swift](https://img.shields.io/badge/Swift-AppKit-orange)](https://github.com/antoine-debroye/markpad)

Markdown renders as you type. Tables are grids, images are pictures, diagrams are diagrams — and the moment your caret enters a block, its raw syntax comes back so you can edit it. Swift and AppKit throughout: no Electron, and no web view in the editor.

### [⬇ Download the latest release](https://github.com/antoine-debroye/markpad/releases/latest)

Open the disk image and drag Markpad to Applications. Signed and notarized, and it keeps itself up to date from then on.

---

## What it does

**Writes like a document, saves like Markdown.** One pane, no split preview. The file on disk is always plain Markdown — undo, find, copy and save all operate on exactly what you typed.

**Shows your content, not your markup.** Tables are drawn as grids, images and Mermaid diagrams appear in place, code blocks are coloured by language, and task boxes are clickable.

**Converts almost anything.** Markdown to Word (`.docx`), HTML or plain text. PDFs and images *back* to Markdown, using on-device text recognition — nothing is uploaded, and long documents show progress you can cancel.

**Works from anywhere in macOS.** Press Space on a `.md` file in the Finder for a formatted preview. Drop a PDF on the Dock icon to convert it. Shortcuts actions cover every conversion, so a Quick Action or a hotkey does the whole job.

**Light, Dark or Automatic**, applied to the editor, previews and exported HTML alike.

## Requirements

macOS 14 or later, Apple silicon or Intel.

## Updates

Markpad checks for updates once a day and installs them in the background, applying them the next time it launches. "Check for Updates…" is in the Markpad menu, and there is a switch in Settings to turn the background checks off.

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

## Known limits

- A table wider than the window is drawn as a grid and reached by scrolling sideways; prose keeps wrapping at the window width while it does.
- Diagrams appear in the editor and in exported HTML. Word and plain-text exports carry the diagram's source rather than a picture.
- Syntax highlighting is a tokenizer, not a parser: it colours comments, strings, numbers, keywords and type names, which covers reading code in a document but will not match a full language grammar.
- PDF extraction targets single-column documents. Multi-column layouts, footnotes and complex tables are best effort.
- Remote images (`https://…`) are not downloaded; an editor should not make network requests while you type. Local images render.
- No LaTeX rendering.

---

# Building from source

Requires Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./scripts/build.sh
```

The generated `Markpad.xcodeproj` is not checked in — `project.yml` is the source of truth, so regenerate it after changing targets or settings.

To run the app from the Finder, and to make Quick Look and Shortcuts pick it up reliably, install it:

```bash
./scripts/build.sh release && cp -R dist/Markpad.app /Applications/
```

For a disk image with the usual drag-to-install window:

```bash
./scripts/package.sh
```

This writes `dist/Markpad-<version>.dmg`. A local build is signed ad-hoc, so the image only opens on the Mac that made it. Set `DEVELOPER_ID` and the image is signed, notarized and stapled too, which is what makes it shareable.

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

Tables and images use the same idea. A table's `|` becomes a control glyph whose width is exactly the distance to the next column boundary, so cells line up without a character being moved; an image's first character becomes a box the size of the picture, and the line grows to fit it. Both revert to plain source when the caret enters the block, so everything stays editable.

Three details that are easy to get wrong and are covered by tests:

- **Offsets.** cmark reports positions as UTF-8 byte columns while `NSTextStorage` counts UTF-16 units. Every document containing an emoji, an accent or CJK text puts the two out of step, so all conversion goes through `SourceIndex`.
- **Quick Look and untrusted files.** Markdown permits inline HTML, and exports pass it through. Previews do not: Quick Look renders files the user merely selected in the Finder, so embedded markup is escaped rather than executed.
- **Nothing disappears.** An image that is missing or still loading keeps its Markdown on screen, and a table too wide for the window keeps its pipes, rather than leaving a blank gap where content should be.

### Why the sandbox is off

A sandboxed document app may read the file it was handed and nothing beside it, so `![diagram](images/flow.png)` could never be displayed — the picture is a sibling file the app is not allowed to open. Since Markpad is distributed with Developer ID rather than through the App Store, where the sandbox is optional, it runs unsandboxed so relative image paths work.

The alternative is to keep the sandbox and ask for folder access through an open panel, storing a security-scoped bookmark per folder. That puts a permission dialog in front of ordinary Markdown files. `Markpad/Markpad.entitlements` carries the reasoning and re-enabling the sandbox is a one-line change; inline images with relative paths stop working, and everything else continues to.

### Diagrams

A ` ```mermaid ` block is drawn as a picture. Mermaid is a JavaScript library, so there is no native path: a hidden web view runs it and returns both an SVG and a snapshot — the snapshot is drawn in the editor, the SVG is embedded in exported HTML so the export needs no scripts to display it.

The library is bundled rather than fetched from a CDN, so diagrams render offline and a document never causes a network request while you type. A diagram that Mermaid cannot parse keeps its source on screen instead of leaving a gap.

### Dependencies

[swift-markdown](https://github.com/swiftlang/swift-markdown) for parsing, [Sparkle](https://sparkle-project.org) for updates, and a bundled copy of [Mermaid](https://mermaid.js.org) (MIT licensed, `Markpad/Resources/Mermaid/`) for diagrams. The `.docx` writer emits OOXML directly and packages it with a small built-in ZIP writer, which keeps the app free of a third-party archiver and its signing and notarization overhead.

## Versioning

`project.yml` holds both numbers, and the app and the Quick Look extension read the same pair — a nested extension whose version has drifted from its host fails signature validation. Bump them with:

```bash
./scripts/version.sh patch
```

`patch`, `minor` and `major` move the marketing version; `set 2.0.0` fixes it outright; `build` leaves it alone and moves the build number only. Every bump also raises the build number, which is never reset — macOS expects it to increase monotonically, and Apple rejects a notarisation that reuses a version, so one ever-rising counter makes reuse impossible. Run `./scripts/version.sh` on its own to print the current version.

## Releasing

Updates are signed with an EdDSA key that is created once:

```bash
./scripts/appcast.sh setup
```

The private key goes into your login keychain and the public half into `project.yml`. **Back the private key up somewhere offline.** Losing it ends updating permanently for everyone already running Markpad: they verify against the public key baked into their copy and will refuse anything signed by a different one. Until this is run, `SUPublicEDKey` is empty and updating stays switched off — Sparkle will not install something it cannot verify.

Cutting a release then takes four steps:

```bash
./scripts/version.sh minor
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/notarize.sh
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/package.sh --no-build
./scripts/appcast.sh
```

That leaves the archive, the disk image and `appcast.xml` ready to publish; `appcast.sh` prints the `gh release create` line. Notarizing is not optional here — an ad-hoc build downloads and then refuses to launch — and it needs a paid Apple Developer account: a Developer ID certificate in your keychain and a `notarytool` credential profile. The scripts' headers list the one-off setup commands.

The feed is served from the newest GitHub release, so the update goes live when that release is published. GitHub's "latest" pointer can lag a couple of minutes behind; the feed catches up on its own.
