import Foundation
import Darwin

/// Result of a DNS lookup for a single host.
struct ResolvedHost {
    let hostname: String
    /// The address family the host resolved to, or nil when resolution failed.
    let family: HostAddressFamily?
    /// The address in presentation form (dotted quad / compressed IPv6), nil on failure.
    let displayIP: String?
    let error: String?

    var isResolved: Bool { family != nil }
}

/// Async DNS resolver with an in-memory TTL cache.
/// Decouples name resolution from the probe loop so send-path latency is flat.
actor DNSResolver {
    private struct CacheEntry {
        let family: HostAddressFamily
        let display: String
        let expiresAt: Date
    }

    /// A lookup is family-scoped: the same host resolved IPv4-only vs IPv6-first
    /// is two different answers, so both parts form the key.
    private struct CacheKey: Hashable {
        let host: String
        let preferIPv6: Bool
    }

    private var cache: [CacheKey: CacheEntry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 300) { self.ttl = ttl }

    /// Resolve `host`. Literal addresses always keep their own family (no DNS).
    /// For hostnames, `preferIPv6` selects the family: off resolves IPv4 (A) only;
    /// on resolves IPv6 (AAAA) first and falls back to IPv4 (A) when the name has
    /// no AAAA. The flag is part of the cache key so toggling never serves a
    /// stale family.
    func resolve(_ host: String, preferIPv6: Bool) async -> ResolvedHost {
        let key = CacheKey(host: host, preferIPv6: preferIPv6)
        if let hit = cache[key], hit.expiresAt > Date() {
            return ResolvedHost(hostname: host, family: hit.family, displayIP: hit.display, error: nil)
        }
        let looked = await Self.lookup(host, preferIPv6: preferIPv6)
        if let family = looked.family, let disp = looked.displayIP {
            cache[key] = CacheEntry(family: family, display: disp, expiresAt: Date().addingTimeInterval(ttl))
        }
        return looked
    }

    func resolveAll(_ hosts: [String], preferIPv6: Bool) async -> [ResolvedHost] {
        await withTaskGroup(of: ResolvedHost.self) { group in
            for h in hosts { group.addTask { await self.resolve(h, preferIPv6: preferIPv6) } }
            var out: [ResolvedHost] = []
            out.reserveCapacity(hosts.count)
            for await r in group { out.append(r) }
            return out
        }
    }

    func invalidate(_ host: String) {
        cache = cache.filter { $0.key.host != host }
    }
    func clear() { cache.removeAll() }

    // getaddrinfo is blocking — hop off the actor to a background queue.
    private static func lookup(_ host: String, preferIPv6: Bool) async -> ResolvedHost {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: blockingLookup(host, preferIPv6: preferIPv6))
            }
        }
    }

    private static func blockingLookup(_ host: String, preferIPv6: Bool) -> ResolvedHost {
        // Literal addresses skip DNS entirely and keep their own family.
        // IPv4-mapped literals are reported in their dotted IPv4 form.
        if let family = HostValidator.literalFamily(host) {
            let display = (family == .ipv4) ? (HostValidator.ipv4MappedString(host) ?? host) : host
            return ResolvedHost(hostname: host, family: family, displayIP: display, error: nil)
        }

        var lastError: String?
        // IPv6 enabled: AAAA first, then A fallback. Otherwise IPv4 (A) only.
        if preferIPv6, let r = resolveName(host, family: .ipv6, error: &lastError) { return r }
        if let r = resolveName(host, family: .ipv4, error: &lastError) { return r }

        return ResolvedHost(hostname: host, family: nil, displayIP: nil,
                            error: lastError ?? "DNS: name resolution failed")
    }

    /// One getaddrinfo pass restricted to `family`. Returns nil when the name has
    /// no address of that family; `error` captures the resolver message.
    private static func resolveName(_ host: String, family: HostAddressFamily,
                                    error: inout String?) -> ResolvedHost? {
        var hints = addrinfo()
        hints.ai_family = (family == .ipv6) ? AF_INET6 : AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, nil, &hints, &result)
        guard rc == 0, let head = result else {
            error = "DNS: \(String(cString: gai_strerror(rc)))"
            return nil
        }
        defer { freeaddrinfo(head) }

        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            if let sa = current.pointee.ai_addr {
                switch family {
                case .ipv6:
                    // Skip IPv4-mapped (::ffff:a.b.c.d) entries — they are IPv4.
                    if !isIPv4Mapped(sa), let disp = presentation(sa, family: .ipv6) {
                        return ResolvedHost(hostname: host, family: .ipv6, displayIP: disp, error: nil)
                    }
                case .ipv4:
                    if let disp = presentation(sa, family: .ipv4) {
                        return ResolvedHost(hostname: host, family: .ipv4, displayIP: disp, error: nil)
                    }
                }
            }
            node = current.pointee.ai_next
        }
        return nil
    }

    /// Numeric form of a sockaddr of the requested family, via inet_ntop.
    private static func presentation(_ sa: UnsafeMutablePointer<sockaddr>,
                                     family: HostAddressFamily) -> String? {
        if family == .ipv6 {
            guard sa.pointee.sa_family == sa_family_t(AF_INET6) else { return nil }
            let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            var addr = sin6.sin6_addr
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buf)
        } else {
            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var addr = sin.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buf)
        }
    }

    /// True for the IPv4-mapped range ::ffff:0:0/96 (a sockaddr_in6 from getaddrinfo).
    private static func isIPv4Mapped(_ sa: UnsafeMutablePointer<sockaddr>) -> Bool {
        guard sa.pointee.sa_family == sa_family_t(AF_INET6) else { return false }
        return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            HostValidator.isIPv4Mapped($0.pointee.sin6_addr)
        }
    }
}
