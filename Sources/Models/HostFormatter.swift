import Foundation

struct HostFormatter {
    /// Split `input` into hosts, cleaning up the noise that comes with pasted
    /// text: full-width characters (NFKC folds `１０．３２．４．１` back to ASCII),
    /// invisible joiners/BOMs/marks, and every flavour of whitespace, comma or
    /// semicolon as a separator. Duplicates collapse on a canonical key.
    static func parse(_ input: String) -> [String] {
        var separators = CharacterSet.whitespacesAndNewlines
        separators.insert(charactersIn: ",;|")

        var seen = Set<String>()
        var result: [String] = []

        for token in sanitize(input).components(separatedBy: separators) {
            guard !token.isEmpty else { continue }
            // Deduplicate on a canonical key. Hostnames just fold case, but IPv6
            // literals have many equivalent textual forms (`2001:db8::1` and
            // `2001:0db8:0:0:0:0:0:1`), so an address is normalized to its
            // compressed form for comparison — otherwise the same host is pinged
            // twice. The user's own text is preserved for display.
            if seen.insert(dedupeKey(token)).inserted {
                result.append(token)
            }
        }

        return result
    }

    /// The input rewritten one host per line, deduplicated.
    static func format(_ input: String) -> String {
        parse(input).joined(separator: "\n")
    }

    /// Remove the characters that are invisible in a text field or copied along
    /// with formatted text, and fold compatibility forms (full-width digits and
    /// punctuation) to plain ASCII. Without this, pasting `10.32.4.151` from a
    /// chat or document can carry a zero-width space or a non-breaking space and
    /// the row reads as an invalid host even though it looks correct.
    static func sanitize(_ input: String) -> String {
        let normalized = input.precomposedStringWithCompatibilityMapping
        var output = String.UnicodeScalarView()
        output.reserveCapacity(normalized.unicodeScalars.count)
        for scalar in normalized.unicodeScalars {
            if invisible.contains(scalar.value) { continue }
            output.append(scalar)
        }
        return String(output)
    }

    /// A key under which two entries that mean the same host compare equal.
    /// Shared with the engine so the Start path dedupes identically to Format.
    static func dedupeKey(_ host: String) -> String {
        let lowered = host.lowercased()
        return HostValidator.canonicalLiteral(lowered) ?? lowered
    }

    /// Zero-width and directional formatting characters plus the BOM. All of
    /// them survive a naive copy/paste but are invisible in the editor.
    private static let invisible: Set<UInt32> = [
        0x00AD,  // soft hyphen
        0x200B,  // zero width space
        0x200C,  // zero width non-joiner
        0x200D,  // zero width joiner
        0x200E,  // left-to-right mark
        0x200F,  // right-to-left mark
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,  // directional embedding/override
        0x2060,  // word joiner
        0x2066, 0x2067, 0x2068, 0x2069,          // directional isolates
        0xFEFF,  // byte order mark / zero width no-break space
    ]
}
