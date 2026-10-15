import Foundation

enum L10n {
    private static let bundle: Bundle = {
        // Packaged apps keep SwiftPM resources inside Contents/Resources.
        if let url = Bundle.main.url(forResource: "Echo_Echo", withExtension: "bundle"),
           let resources = Bundle(url: url) {
            return resources
        }
        return Bundle.module
    }()

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
