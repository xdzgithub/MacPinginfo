import Foundation

enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ argument: CVarArg) -> String {
        String(format: string(key), argument)
    }
}
