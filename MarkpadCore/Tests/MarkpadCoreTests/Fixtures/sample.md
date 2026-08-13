# Markpad Sample Document

This paragraph exercises **bold text**, *italic text*, ***both at once***,
~~strikethrough~~, `inline code`, and a [link to Apple](https://www.apple.com "Apple Home").

## Lists

An unordered list:

- First item
- Second item with **emphasis**
  - Nested item one
  - Nested item two
- Third item

An ordered list:

1. Prepare the document
2. Convert it
3. Ship it

A task list:

- [x] Write the exporter
- [ ] Write the importer
- [ ] Ship version one

### Block quotes

> A quote spanning a single paragraph.
>
> And a second paragraph inside the same quote.

### Code

Some prose before a fenced block.

```swift
struct Greeter {
    let name: String
    func greet() -> String { "Hello, \(name)!" }
}
```

Indented output follows.

## Tables

| Format | Extension | Lossless |
| --- | :---: | ---: |
| Word | docx | no |
| HTML | html | yes |
| Plain text | txt | no |

## Horizontal rule

---

## Deeper headings

#### Level four
##### Level five
###### Level six

A final paragraph with an autolink <https://swift.org> and a trailing sentence.
