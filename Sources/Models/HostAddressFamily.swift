import Foundation

/// The IP version a host resolves to and is probed over.
///
/// Literal addresses carry their family implicitly; for hostnames it is decided
/// by name resolution (`DNSResolver`).
enum HostAddressFamily: String {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"

    var displayName: String { rawValue }
}
