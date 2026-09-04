import Foundation

/// A formatting command sent from the Format menu to the focused editor.
///
/// Declared beside the editor rather than with the menu, because both the app and the Quick
/// Look extension compile the editor and only the app has menus.
enum FormattingAction {
    case bold
    case italic
    case code
    case link

    var wrapper: String? {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .code: return "`"
        case .link: return nil
        }
    }
}

extension Notification.Name {
    static let markpadFormatting = Notification.Name("markpad.formatting")
    static let markpadScrollToLocation = Notification.Name("markpad.scrollToLocation")
}
