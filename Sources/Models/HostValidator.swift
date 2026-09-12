import Foundation
import Darwin

/// Syntactic validation for user-entered hosts.
///
/// A host is accepted when it is either a literal IPv4 address or a hostname
/// that follows RFC 1123 label rules. The app resolves and pings over IPv4, so
/// the IP fast-path is deliberately IPv4-only.
enum HostValidator {
    static func isValid(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }

        if isIPv4(trimmed) { return true }

        // A token made only of digits and dots was meant as an IP address.
        // Don't let it fall through to the (more permissive) hostname path.
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." }) { return false }

        return isHostname(trimmed)
    }

    static func isIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, s, &addr) == 1
    }

    private static let labelCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    static func isHostname(_ s: String) -> Bool {
        var name = s
        if name.hasSuffix(".") { name.removeLast() }   // allow a fully-qualified trailing dot
        guard !name.isEmpty else { return false }

        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }

        for sub in labels {
            let label = String(sub)
            guard (1...63).contains(label.count) else { return false }
            guard label.unicodeScalars.allSatisfy({ labelCharacters.contains($0) }) else { return false }
            guard let first = label.first, let last = label.last,
                  first.isLetter || first.isNumber,
                  last.isLetter || last.isNumber else { return false }
        }

        // A purely numeric TLD is never a real hostname.
        if let tld = labels.last, String(tld).allSatisfy({ $0.isNumber }) { return false }
        return true
    }
}
