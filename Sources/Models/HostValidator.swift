import Foundation
import Darwin

/// Syntactic validation for user-entered hosts.
///
/// A host is accepted when it is a literal IPv4 address, a literal IPv6 address,
/// or a hostname that follows RFC 1123 label rules. The literal family is matched
/// from its syntax; only a hostname needs name resolution to pick a family.
enum HostValidator {
    static func isValid(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }

        if isIPv4(trimmed) { return true }
        if isIPv6(trimmed) { return true }

        // A token made only of digits and dots was meant as an IP address.
        // Don't let it fall through to the (more permissive) hostname path.
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." }) { return false }

        return isHostname(trimmed)
    }

    /// Strict dotted-quad IPv4 literal.
    ///
    /// Deliberately not `inet_pton(AF_INET,…)`: Darwin's implementation accepts
    /// leading zeros (`1.1.01.1`, `010.0.0.1`), which are ambiguous — historically
    /// octal, so `010` means 8 to some parsers and 10 to others — and rejected by
    /// most validators. We require plain decimal octets: four parts, 1–3 digits,
    /// no leading zero unless the octet is exactly "0", value 0…255.
    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            if part.count > 1 && part.first == "0" { return false }
            guard let value = Int(part), (0...255).contains(value) else { return false }
        }
        return true
    }

    /// Strict IPv6 literal, including a validated `%zone` scope id.
    static func isIPv6(_ s: String) -> Bool {
        parseIPv6(s) != nil
    }

    /// Strict IPv6 parse: the 16 address bytes plus an optional zone id.
    ///
    /// `inet_pton(AF_INET6,…)` alone is too lax on Darwin in three ways, all fixed
    /// here before deferring to it for the core structure:
    ///  - an embedded IPv4 tail may use leading zeros (`::ffff:1.1.01.1`), so the
    ///    dotted quad is validated with the strict `isIPv4`;
    ///  - the `%zone` scope id is accepted even when empty (`fe80::1%`) or when it
    ///    contains junk (`fe80::1%a b`), so the zone must look like an interface
    ///    name;
    ///  - a zone is accepted on any address, but a scope id is only meaningful for
    ///    a non-global address, so it is rejected on a global one
    ///    (`2001:db8::1%en0`).
    static func parseIPv6(_ s: String) -> (address: in6_addr, zone: String?)? {
        let address: String
        let zone: String?
        if let pct = s.firstIndex(of: "%") {
            let z = String(s[s.index(after: pct)...])
            guard isZoneName(z) else { return nil }
            zone = z
            address = String(s[..<pct])
        } else {
            zone = nil
            address = s
        }

        // A dotted tail is an embedded IPv4 address; it must be strict too, or
        // `::ffff:1.1.01.1` would slip through on the leading zero.
        if address.contains(".") {
            guard let colon = address.lastIndex(of: ":"),
                  isIPv4(String(address[address.index(after: colon)...])) else { return nil }
        }

        var addr = in6_addr()
        guard inet_pton(AF_INET6, address, &addr) == 1 else { return nil }
        if zone != nil, !allowsZone(addr) { return nil }
        return (addr, zone)
    }

    /// A scope id looks like an interface name: an alphanumeric first character,
    /// then letters, digits, `.`, `-`, or `_` (covers `en0`, `utun3`, `en0.100`).
    private static func isZoneName(_ z: String) -> Bool {
        guard let first = z.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return z.allSatisfy(isZoneCharacter)
    }

    private static func isZoneCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-" || c == "_")
    }

    /// A scope id is meaningful only for a non-global address: link-local
    /// (`fe80::/10`), site-local (`fec0::/10`), multicast (`ff00::/8`), or
    /// loopback (`::1`). Elsewhere it is meaningless, so its presence is invalid.
    private static func allowsZone(_ addr: in6_addr) -> Bool {
        let b = byteArray(addr)
        if b[0] == 0xff { return true }                                   // multicast
        if b[0] == 0xfe, b[1] >= 0x80 { return true }                     // link-local / site-local
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }  // ::1 loopback
        return false
    }

    private static func byteArray(_ addr: in6_addr) -> [UInt8] {
        withUnsafeBytes(of: addr) { Array($0) }
    }

    /// The literal family of `host`, or nil when it is not a literal IP address.
    /// An IPv4-mapped IPv6 literal (`::ffff:a.b.c.d`) is IPv4 for pinging — it
    /// addresses an IPv4 host, and ping6 cannot send to it.
    static func literalFamily(_ host: String) -> HostAddressFamily? {
        if isIPv4(host) { return .ipv4 }
        if let a6 = ipv6Bytes(host) { return isIPv4Mapped(a6) ? .ipv4 : .ipv6 }
        return nil
    }

    /// The 16 address bytes of an IPv6 literal (zone stripped), or nil when `s`
    /// is not a strict IPv6 literal.
    static func ipv6Bytes(_ s: String) -> in6_addr? {
        parseIPv6(s)?.address
    }

    /// True for the IPv4-mapped range `::ffff:0:0/96`.
    static func isIPv4Mapped(_ addr: in6_addr) -> Bool {
        let bytes = byteArray(addr)
        guard bytes.count == 16 else { return false }
        return bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
    }

    /// For an IPv4-mapped IPv6 literal, the embedded dotted-quad; else nil.
    static func ipv4MappedString(_ s: String) -> String? {
        guard let a6 = ipv6Bytes(s) else { return nil }
        return embeddedIPv4String(a6)
    }

    /// The dotted quad embedded in an IPv4-mapped address, or nil.
    static func embeddedIPv4String(_ addr: in6_addr) -> String? {
        guard isIPv4Mapped(addr) else { return nil }
        let quad = Array(byteArray(addr)[12..<16])
        var v4 = in_addr()
        withUnsafeMutableBytes(of: &v4) { $0.copyBytes(from: quad) }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &v4, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    /// Canonical (compressed) presentation form of a literal IP address, via
    /// inet_ntop — collapses equivalent IPv6 spellings (`2001:db8::1` and
    /// `2001:0db8:0:0:0:0:0:1` compare equal). An IPv4-mapped literal reduces to
    /// the dotted IPv4 it addresses, since that is what gets pinged. A scope id is
    /// preserved so `fe80::1%en0` and `fe80::1%en1` stay distinct. nil for
    /// hostnames.
    static func canonicalLiteral(_ host: String) -> String? {
        if isIPv4(host) { return host }
        guard let parsed = parseIPv6(host) else { return nil }
        // A mapped address is pinged as IPv4 and carries no meaningful zone.
        if let mapped = embeddedIPv4String(parsed.address) { return mapped }
        var a6 = parsed.address
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &a6, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        let base = String(cString: buf)
        return parsed.zone.map { "\(base)%\($0)" } ?? base
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
