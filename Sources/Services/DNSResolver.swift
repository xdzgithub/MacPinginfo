import Foundation
import Darwin

/// Result of a DNS lookup for a single host.
struct ResolvedHost {
    let hostname: String
    let ipv4: UInt32?          // network byte order, 0 when failed
    let displayIP: String?     // dotted form, nil when failed
    let error: String?
}

/// Async DNS resolver with an in-memory TTL cache.
/// Decouples name resolution from the probe loop so send-path latency is flat.
actor DNSResolver {
    private struct CacheEntry {
        let ipv4: UInt32
        let display: String
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 300) { self.ttl = ttl }

    func resolve(_ host: String) async -> ResolvedHost {
        if let hit = cache[host], hit.expiresAt > Date() {
            return ResolvedHost(hostname: host, ipv4: hit.ipv4, displayIP: hit.display, error: nil)
        }
        let looked = await Self.lookup(host)
        if let ip = looked.ipv4, let disp = looked.displayIP {
            cache[host] = CacheEntry(ipv4: ip, display: disp, expiresAt: Date().addingTimeInterval(ttl))
        }
        return looked
    }

    func resolveAll(_ hosts: [String]) async -> [ResolvedHost] {
        await withTaskGroup(of: ResolvedHost.self) { group in
            for h in hosts { group.addTask { await self.resolve(h) } }
            var out: [ResolvedHost] = []
            out.reserveCapacity(hosts.count)
            for await r in group { out.append(r) }
            return out
        }
    }

    func invalidate(_ host: String) { cache.removeValue(forKey: host) }
    func clear() { cache.removeAll() }

    // getaddrinfo is blocking — hop off the actor to a background queue.
    private static func lookup(_ host: String) async -> ResolvedHost {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: blockingLookup(host))
            }
        }
    }

    private static func blockingLookup(_ host: String) -> ResolvedHost {
        // Literal IPv4 fast-path avoids DNS entirely.
        var literal = in_addr()
        if inet_pton(AF_INET, host, &literal) == 1 {
            let ip = literal.s_addr
            return ResolvedHost(hostname: host, ipv4: ip, displayIP: host, error: nil)
        }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, nil, &hints, &result)
        guard rc == 0, let head = result else {
            let msg = String(cString: gai_strerror(rc))
            return ResolvedHost(hostname: host, ipv4: nil, displayIP: nil, error: "DNS: \(msg)")
        }
        defer { freeaddrinfo(head) }

        guard let sa = head.pointee.ai_addr else {
            return ResolvedHost(hostname: host, ipv4: nil, displayIP: nil, error: "DNS: empty result")
        }
        let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        let ip = sin.sin_addr.s_addr
        var display = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addrCopy = sin.sin_addr
        inet_ntop(AF_INET, &addrCopy, &display, socklen_t(INET_ADDRSTRLEN))
        let disp = String(cString: display)
        return ResolvedHost(hostname: host, ipv4: ip, displayIP: disp, error: nil)
    }
}
