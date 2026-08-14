import Foundation

/// Fenced-block languages that describe a picture rather than code.
public enum DiagramLanguage {
    public static let mermaid = "mermaid"

    public static func isDiagram(_ language: String) -> Bool {
        language.lowercased() == mermaid
    }
}
