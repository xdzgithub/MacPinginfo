import Foundation
import Darwin
import SwiftUI

// MARK: - PingEngine
//
// One persistent /sbin/ping process per host, reading stdout line-by-line.
// This eliminates the false-timeout problem caused by spawn-per-ping:
// the kernel ICMP stack delivers replies to the same socket that sent them,
// and the streaming parser picks up every line as it arrives — no reply is
// ever lost to a process-exit race condition.

@MainActor
final class PingEngine: ObservableObject {
    @Published private(set) var results: [PingResult] = []
    @Published private(set) var isRunning: Bool = false
    /// When on, reachable (online) hosts are kept at the top after every ping.
    @Published private(set) var pinOnlineToTop: Bool = false

    private var processes: [String: Process] = [:]
    private var handlers: [String: DispatchSourceRead] = [:]
    private var outputBuffers: [String: String] = [:]
    private let resolver = DNSResolver()

    /// Hostnames currently probed over IPv6 that resolved from a name (not a
    /// literal). Only these are eligible to downgrade to IPv4 if IPv6 is dead.
    private var ipv6ByName: Set<String> = []
    /// Hostnames already downgraded, so a fallback is attempted at most once.
    private var downgradedHosts: Set<String> = []
    /// Consecutive failures before a row flips to `.offline`.
    private let offlineFailureThreshold = 2
    /// Consecutive IPv6 failures before a hostname downgrades to IPv4. Equal to
    /// the offline threshold so a dead IPv6 host falls back the moment it would
    /// otherwise be painted offline, rather than showing "Offline" for a cycle.
    private let ipv6FallbackThreshold = 2

    var pingInterval: TimeInterval = 1.0
    /// "Resolve hostnames via IPv6". Off (default) resolves hostnames to IPv4;
    /// on resolves them IPv6 (AAAA) first and automatically downgrades a hostname
    /// to IPv4 when IPv6 turns out to be unreachable. Literal IP addresses are
    /// always auto-detected regardless of this flag.
    var resolveHostnamesViaIPv6: Bool = false

    // MARK: - Public API

    func start(hosts: [String]) {
        guard !isRunning else { return }
        guard !hosts.isEmpty else { return }

        // Collapse duplicates up front. Each host gets one process keyed by
        // hostname, so a repeated entry would overwrite the dictionary slot and
        // orphan the earlier process (never terminated by stop()). Use the same
        // canonical key as Format so equivalent IPv6 spellings also collapse.
        var seen = Set<String>()
        let uniqueHosts = hosts.filter { seen.insert(HostFormatter.dedupeKey($0)).inserted }

        let invalidSuffix = L10n.string("Host.InvalidSuffix")
        var validHosts: [String] = []
        results = uniqueHosts.map { host in
            if HostValidator.isValid(host) {
                validHosts.append(host)
                return PingResult(hostname: host, status: .waiting)
            }
            return PingResult(hostname: host + invalidSuffix, isInvalid: true, status: .invalid)
        }
        reorderForPin()

        // Nothing to probe — every entry failed syntax validation. Keep the rows
        // visible but stay idle, rather than entering a run state with no
        // processes (which would leave the UI stuck on "Stop" forever).
        guard !validHosts.isEmpty else { return }
        isRunning = true

        Task {
            let resolved = await resolver.resolveAll(validHosts, preferIPv6: resolveHostnamesViaIPv6)
            guard isRunning else { return }

            for r in resolved {
                guard let idx = results.firstIndex(where: { $0.hostname == r.hostname }) else { continue }
                results[idx].family = r.family
                results[idx].resolvedIP = r.displayIP
                if !r.isResolved {
                    results[idx].recordPing(success: false, latency: nil,
                                           error: r.error ?? "DNS failed",
                                           offlineThreshold: offlineFailureThreshold)
                } else if r.family == .ipv6, HostValidator.literalFamily(r.hostname) == nil {
                    // A hostname that resolved to IPv6 may later downgrade to IPv4
                    // if IPv6 is unreachable.
                    ipv6ByName.insert(r.hostname)
                }
            }
            reorderForPin()

            let okHosts = resolved.filter { $0.isResolved }
            for r in okHosts where isRunning {
                spawnStreamingPing(for: r)
            }
        }
    }

    func stop() {
        isRunning = false
        for (_, proc) in processes {
            proc.terminate()
        }
        processes.removeAll()
        handlers.removeAll()
        outputBuffers.removeAll()
        ipv6ByName.removeAll()
        downgradedHosts.removeAll()
    }

    func clear() {
        stop()
        results = []
    }

    // MARK: - Row ordering

    /// Toggle the "reachable hosts on top" mode. Turning it off freezes the
    /// current arrangement instead of restoring the original input order.
    func togglePinOnlineToTop() {
        pinOnlineToTop.toggle()
        if pinOnlineToTop { reorderForPin() }
    }

    /// Stable partition: online rows first, everything else after, preserving
    /// each group's existing relative order.
    private func reorderForPin() {
        guard pinOnlineToTop else { return }
        let online = results.filter { $0.status == .online }
        guard !online.isEmpty, online.count < results.count else { return }
        let reordered = online + results.filter { $0.status != .online }
        if reordered.map(\.id) != results.map(\.id) {
            // Animate only this reorder. Driving the animation here — rather than
            // a blanket .animation on the table — lets reachable rows slide to
            // the top on each ping while a Start still appears instantly.
            withAnimation(.easeInOut(duration: 0.25)) {
                results = reordered
            }
        }
    }

    // MARK: - Persistent ping process

    private func spawnStreamingPing(for r: ResolvedHost) {
        guard let family = r.family, let target = r.displayIP else { return }

        let proc = Process()
        // macOS ships a separate ping6 for IPv6; /sbin/ping rejects -6.
        proc.executableURL = URL(fileURLWithPath: family == .ipv6 ? "/sbin/ping6" : "/sbin/ping")
        var args: [String] = []
        if family == .ipv4 { args.append("-n") }   // ping6 is always numeric
        // Probe the numeric address we resolved: stable across the run and the
        // only form that works for a remapped literal like ::ffff:a.b.c.d.
        args += ["-i", String(format: "%.1f", pingInterval), "-c", "99999", target]
        proc.arguments = args
        proc.environment = ["LC_ALL": "C"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        processes[r.hostname] = proc

        let source = DispatchSource.makeReadSource(fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                                                    queue: .global(qos: .userInitiated))
        handlers[r.hostname] = source
        outputBuffers[r.hostname] = ""

        source.setEventHandler { [weak self] in
            let data = pipe.fileHandleForReading.availableData
            guard !data.isEmpty else {
                // EOF — process ended. Pass this process so an earlier generation
                // (e.g. an IPv6 probe replaced during a downgrade) can't be
                // mistaken for the current one.
                Task { @MainActor [weak self] in
                    self?.handleProcessEnd(hostname: r.hostname, process: proc)
                }
                return
            }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                self?.parseOutput(hostname: r.hostname, chunk: chunk)
            }
        }
        source.setCancelHandler {
            pipe.fileHandleForReading.closeFile()
        }

        do {
            try proc.run()
        } catch {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let idx = self.results.firstIndex(where: { $0.hostname == r.hostname }) {
                    self.results[idx].recordPing(success: false, latency: nil,
                                                 error: "ping launch failed",
                                                 offlineThreshold: offlineFailureThreshold)
                }
            }
        }

        source.resume()
    }

    private func parseOutput(hostname: String, chunk: String) {
        guard isRunning else { return }
        outputBuffers[hostname, default: ""].append(chunk)

        // Process line by line — keep incomplete last line in buffer
        var buffer = outputBuffers[hostname] ?? ""
        var lines = buffer.components(separatedBy: "\n")
        if !buffer.hasSuffix("\n") {
            buffer = lines.removeLast()
            outputBuffers[hostname] = buffer
        } else {
            outputBuffers[hostname] = ""
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let latency = parseTimeLine(trimmed) {
                applyOne(hostname: hostname, success: true, latency: latency, error: nil)
            } else if isErrorLine(trimmed) {
                applyOne(hostname: hostname, success: false, latency: nil, error: trimmed)
            }
        }
    }

    private func handleProcessEnd(hostname: String, process: Process) {
        // Ignore EOF from a superseded process (downgrade or a prior run).
        guard isRunning, let proc = processes[hostname], proc === process else { return }
        let code = proc.terminationStatus
        if code != 0 {
            applyOne(hostname: hostname, success: false, latency: nil,
                    error: "process exited: \(code)")
        }
        processes.removeValue(forKey: hostname)
        handlers.removeValue(forKey: hostname)
        outputBuffers.removeValue(forKey: hostname)
    }

    // MARK: - Line parsing

    private func parseTimeLine(_ line: String) -> Double? {
        // Matches: "64 bytes from 8.8.8.8: icmp_seq=0 ttl=117 time=11.3 ms"
        // Also handles: "time=11.3 ms" variants
        let patterns = [
            #"time[=<]?\s*([0-9]+\.?[0-9]*)\s*ms"#,
            #"time[=<]?\s*<([0-9]+\.?[0-9]*)\s*ms"#,
            #"time[=<]?\s*([0-9]+\.?[0-9]*)\s*msec"#,
        ]
        for pat in patterns {
            guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: range),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: line),
                  let v = Double(line[r]), v >= 0 else { continue }
            return v
        }
        return nil
    }

    private func isErrorLine(_ line: String) -> Bool {
        // Skip summary/statistics lines. Both binaries announce themselves with a
        // "PING ..." (v4) or "PING6(..." (v6) header.
        if line.hasPrefix("---")          { return false }
        if line.hasPrefix("PING")         { return false }
        if line.hasPrefix("ping: ")       { return true }
        if line.hasPrefix("ping6: ")      { return true }
        if line.hasPrefix("Request timeout") { return true }
        if line.contains("Unknown host") { return true }
        if line.contains("no route")     { return true }
        if line.contains("Destination Host Unreachable") { return true }
        return false
    }

    // MARK: - Result application

    private func applyOne(hostname: String, success: Bool, latency: Double?, error: String?) {
        guard isRunning else { return }
        if let idx = results.firstIndex(where: { $0.hostname == hostname }) {
            results[idx].recordPing(success: success, latency: latency,
                                   error: error, offlineThreshold: offlineFailureThreshold)
            reorderForPin()

            if !success, shouldDowngradeToIPv4(hostname,
                                               failures: results[idx].consecutiveFailures,
                                               error: error) {
                downgradeToIPv4(hostname)
            }
        }
    }

    // MARK: - IPv6 → IPv4 downgrade

    /// True when `hostname` is a name-resolved IPv6 host whose IPv6 path looks
    /// dead. A hard "no route / unreachable / invalid" error downgrades
    /// immediately — ping6 exits on those, so a failure count would never climb.
    /// A softer timeout waits for the consecutive-failure threshold. Literal IPv6
    /// addresses are never downgraded: the user asked for that exact address.
    private func shouldDowngradeToIPv4(_ hostname: String, failures: Int, error: String?) -> Bool {
        guard resolveHostnamesViaIPv6,
              ipv6ByName.contains(hostname),
              !downgradedHosts.contains(hostname) else { return false }
        if let error, Self.isHardIPv6Failure(error) { return true }
        return failures >= ipv6FallbackThreshold
    }

    /// Errors that mean the IPv6 path is unusable, not merely slow.
    private static func isHardIPv6Failure(_ error: String) -> Bool {
        let markers = ["no route to host", "network is unreachable",
                       "destination host unreachable", "nodes unreachable",
                       "cannot assign requested address", "invalid argument",
                       "process exited"]
        let lower = error.lowercased()
        return markers.contains { lower.contains($0) }
    }

    /// Re-resolve `hostname` as IPv4 and, if an A record exists, swap the live
    /// IPv6 probe for an IPv4 one and restart the row's statistics.
    private func downgradeToIPv4(_ hostname: String) {
        downgradedHosts.insert(hostname)
        ipv6ByName.remove(hostname)

        Task { [weak self] in
            guard let self else { return }
            let r = await self.resolver.resolve(hostname, preferIPv6: false)
            guard self.isRunning, r.family == .ipv4,
                  let idx = self.results.firstIndex(where: { $0.hostname == hostname }) else { return }
            // Tear down the failing IPv6 process before starting the IPv4 one.
            self.processes[hostname]?.terminate()
            self.handlers[hostname]?.cancel()
            self.processes.removeValue(forKey: hostname)
            self.handlers.removeValue(forKey: hostname)
            self.outputBuffers.removeValue(forKey: hostname)

            self.results[idx].family = r.family
            self.results[idx].resolvedIP = r.displayIP
            self.results[idx].reset()
            self.spawnStreamingPing(for: r)
        }
    }

    // MARK: - CSV export

    /// The current results rendered as CSV text.
    func csvContent() -> String {
        var csv = "Hostname,Family,ResolvedIP,Status,Sent,Received,Lost,Loss%,LastLatency,AvgLatency,LastError\n"
        for r in results {
            let loss = r.sent > 0 ? String(format: "%.1f", r.packetLoss) : "0.0"
            let lat  = r.lastLatency.map   { String(format: "%.2f", $0) } ?? ""
            let avg  = r.averageLatency.map { String(format: "%.2f", $0) } ?? ""
            csv += "\(Self.csvField(r.hostname)),\(r.family?.displayName ?? ""),"
                 + "\(Self.csvField(r.resolvedIP ?? "")),"
                 + "\(r.status.rawValue),\(r.sent),\(r.received),\(r.lost),"
                 + "\(loss)%,\(lat),\(avg),\(Self.csvField(r.lastError ?? ""))\n"
        }
        return csv
    }

    /// Writes the current results to a user-chosen `url`. Returns false if the
    /// write fails (e.g. no permission), so the caller can surface an error.
    @discardableResult
    func exportCSV(to url: URL) -> Bool {
        do {
            try csvContent().write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Quotes a field when it contains a comma, quote, or newline (RFC 4180).
    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
