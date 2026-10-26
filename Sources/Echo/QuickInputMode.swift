import Foundation

/// Mode is UI state, never part of the editable or submitted text.
enum QuickInputMode {
    case search, calculator, chat

    static func trigger(_ text: String) -> Self? {
        switch text {
        case "!", "！": return .calculator
        case "@": return .chat
        default: return nil
        }
    }

    var placeholderKey: String {
        switch self {
        case .search: return "quick.search.placeholder"
        case .calculator: return "quick.calc.placeholder"
        case .chat: return "quick.chat.placeholder"
        }
    }

    var labelKey: String {
        switch self {
        case .search: return "quick.shortcut.search"
        case .calculator: return "calc.title"
        case .chat: return "chat.title"
        }
    }
}
