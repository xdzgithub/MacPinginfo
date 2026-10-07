import Foundation

struct HostFormatter {
    static func format(_ input: String) -> String {
        let separators = CharacterSet(charactersIn: ",\n\r\t;| ")
        let rawHosts = input
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [String] = []

        for host in rawHosts {
            // Deduplicate on a canonical key. Hostnames just fold case, but IPv6
            // literals have many equivalent textual forms (`2001:db8::1` and
            // `2001:0db8:0:0:0:0:0:1`), so an address is normalized to its
            // compressed form for comparison — otherwise the same host is pinged
            // twice. The user's own text is preserved for display.
            let key = dedupeKey(host)
            if !seen.contains(key) {
                seen.insert(key)
                result.append(host)
            }
        }

        return result.joined(separator: "\n")
    }

    /// A key under which two entries that mean the same host compare equal.
    /// Shared with the engine so the Start path dedupes identically to Format.
    static func dedupeKey(_ host: String) -> String {
        let lowered = host.lowercased()
        return HostValidator.canonicalLiteral(lowered) ?? lowered
    }
}
