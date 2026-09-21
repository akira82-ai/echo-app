import Foundation

enum L10n {
    private static let bundle = Bundle.module

    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }

    static func format(_ key: String, _ argument: CVarArg) -> String {
        String.localizedStringWithFormat(text(key), argument)
    }

    static func format(_ key: String, _ first: CVarArg, _ second: CVarArg) -> String {
        String.localizedStringWithFormat(text(key), first, second)
    }
}
