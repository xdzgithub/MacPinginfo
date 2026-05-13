import Foundation
import Darwin

// MARK: - PingEngine
//
// One persistent /sbin/ping process per host, reading stdout line-by-line.
// Sent count is derived exclusively from icmp_seq, never from error lines.

@MainActor
final class PingEngine: ObservableObject {
    @Published private(set) var results: [PingResult] = []
    @Published private(set) var isRunning: Bool = false

    private var processes: [String: Process] = [:]
    private var handlers: [String: DispatchSourceRead] = [:]
    private var outputBuffers: [String: String] = [:]
    private let resolver = DNSResolver()

    // icmp_seq tracking: next expected seq per host.
    // When we see a reply, sent++ always. received++ only on success.
    private var hostNextSeq: [String: UInt16] = [:]
    private var hostLastSeenSeq: [String: UInt16] = [:]

    // Heartbeat timer to detect timeout gaps when host is unreachable.
    private var heartbeatTimers: [String: DispatchSourceTimer] = [:]

    var pingInterval: TimeInterval = 1.0

    // MARK: - Public API

    func start(hosts: [String]) {
        guard !isRunning else { return }
        guard !hosts.isEmpty else { return }

        results = hosts.map { PingResult(hostname: $0, status: .waiting) }
        isRunning = true

        Task {
            let resolved = await resolver.resolveAll(hosts)
            guard isRunning else { return }

            for r in resolved {
                guard let idx = results.firstIndex(where: { $0.hostname == r.hostname }) else { continue }
                results[idx].resolvedIP = r.displayIP
                if r.ipv4 == nil {
                    results[idx].recordPing(success: false, latency: nil,
                                           error: r.error ?? "DNS failed",
                                           offlineThreshold: 2)
                }
            }

            let okHosts = resolved.filter { $0.ipv4 != nil }
            for r in okHosts where isRunning {
                spawnStreamingPing(for: r)
            }
        }
    }

    func stop() {
        isRunning = false
        for (_, proc) in processes { proc.terminate() }
        for (_, t) in heartbeatTimers { t.cancel() }
        processes.removeAll()
        handlers.removeAll()
        outputBuffers.removeAll()
        heartbeatTimers.removeAll()
        hostNextSeq.removeAll()
        hostLastSeenSeq.removeAll()
    }

    func clear() {
        stop()
        results = []
    }

    // MARK: - Persistent ping process

    private func spawnStreamingPing(for r: ResolvedHost) {
        guard r.ipv4 != nil else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/ping")
        proc.arguments = ["-n", "-i", String(format: "%.1f", pingInterval),
                         "-c", "99999", r.hostname]
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
                Task { @MainActor [weak self] in
                    self?.handleProcessEnd(hostname: r.hostname)
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
            startHeartbeat(for: r.hostname)
        } catch {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let idx = self.results.firstIndex(where: { $0.hostname == r.hostname }) {
                    self.results[idx].recordPing(success: false, latency: nil,
                                                 error: "ping launch failed",
                                                 offlineThreshold: 2)
                }
            }
        }

        source.resume()
    }

    // MARK: - Heartbeat: detect missing icmp_seq after timeout

    private func startHeartbeat(for hostname: String) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        heartbeatTimers[hostname] = timer
        // Fire slightly after each expected ping interval
        let intervalNs = UInt64((pingInterval + 0.5) * 1_000_000_000)
        timer.schedule(deadline: .now() + .seconds(Int(pingInterval)), repeating: .nanoseconds(Int(intervalNs)))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkHeartbeat(hostname: hostname)
            }
        }
        timer.resume()
    }

    private func checkHeartbeat(hostname: String) {
        guard isRunning else { return }
        let next = hostNextSeq[hostname] ?? 0
        let last = hostLastSeenSeq[hostname] ?? 0
        guard next > 0 else { return }

        // If next hasn't advanced, packets between last and next are timed out.
        // gap = next - last (accounting for uint16 wrap)
        let gap = Int(next &- last)
        if gap > 0 {
            for _ in 0..<gap {
                applyOne(hostname: hostname, success: false, latency: nil, error: "timeout")
            }
            hostNextSeq[hostname] = next
        }
    }

    // MARK: - Output parsing

    private func parseOutput(hostname: String, chunk: String) {
        guard isRunning else { return }
        outputBuffers[hostname, default: ""].append(chunk)

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
            if let (seq, latency) = parseReplyLine(trimmed) {
                handleReply(hostname: hostname, seq: seq, latency: latency)
            }
        }
    }

    private func handleReply(hostname: String, seq: UInt16, latency: Double?) {
        let next = hostNextSeq[hostname] ?? 0

        if next == 0 {
            // First reply ever — can't infer gap from before it.
            hostNextSeq[hostname] = seq &+ 1
            hostLastSeenSeq[hostname] = seq
            applyOne(hostname: hostname, success: true, latency: latency, error: nil)
            return
        }

        // Wrap-aware gap: how many seq numbers between last and this one?
        let last = hostLastSeenSeq[hostname] ?? next
        let gap = Int(seq &- last)

        if seq == next {
            // In-order expected reply: normal success.
            hostNextSeq[hostname] = seq &+ 1
            hostLastSeenSeq[hostname] = seq
            applyOne(hostname: hostname, success: true, latency: latency, error: nil)
        } else if seq > next {
            // Jumped ahead: packets in [next, seq) are lost.
            for _ in 0..<gap {
                applyOne(hostname: hostname, success: false, latency: nil, error: "timeout")
            }
            hostNextSeq[hostname] = seq &+ 1
            hostLastSeenSeq[hostname] = seq
            applyOne(hostname: hostname, success: true, latency: latency, error: nil)
        }
        // seq < next: late/duplicate reply — ignore.
    }

    private func handleProcessEnd(hostname: String) {
        heartbeatTimers[hostname]?.cancel()
        heartbeatTimers.removeValue(forKey: hostname)
        processes.removeValue(forKey: hostname)
        handlers.removeValue(forKey: hostname)
        outputBuffers.removeValue(forKey: hostname)
    }

    // MARK: - Line parsing

    private func parseReplyLine(_ line: String) -> (UInt16, Double?)? {
        guard line.contains("bytes from") else { return nil }

        var seq: UInt16 = 0
        var latency: Double?

        if let rSeq = line.range(of: #"icmp_seq=(\d+)"#, options: .regularExpression) {
            let num = line[rSeq].dropFirst("icmp_seq=".count)
            seq = UInt16(num) ?? 0
        } else {
            return nil
        }

        let patterns = [
            #"time[=<]?\s*([0-9]+\.?[0-9]*)\s*ms"#,
            #"time[=<]?\s*<([0-9]+\.?[0-9]*)\s*ms"#,
        ]
        for pat in patterns {
            if let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) {
                let range = NSRange(line.startIndex..., in: line)
                if let m = re.firstMatch(in: line, range: range), m.numberOfRanges > 1,
                   let r = Range(m.range(at: 1), in: line),
                   let v = Double(line[r]), v >= 0 {
                    latency = v
                    break
                }
            }
        }

        return (seq, latency)
    }

    // MARK: - Result application

    private func applyOne(hostname: String, success: Bool, latency: Double?, error: String?) {
        guard isRunning else { return }
        if let idx = results.firstIndex(where: { $0.hostname == hostname }) {
            results[idx].recordPing(success: success, latency: latency,
                                   error: error, offlineThreshold: 2)
        }
    }

    // MARK: - CSV export

    func exportCSV() -> URL? {
        var csv = "Hostname,ResolvedIP,Status,Sent,Received,Loss%,LastLatency,AvgLatency,LastError\n"
        for r in results {
            let loss = r.sent > 0 ? String(format: "%.1f", r.packetLoss) : "0.0"
            let lat  = r.lastLatency.map   { String(format: "%.2f", $0) } ?? ""
            let avg  = r.averageLatency.map { String(format: "%.2f", $0) } ?? ""
            let err  = (r.lastError ?? "").replacingOccurrences(of: ",", with: ";")
            csv += "\(r.hostname),\(r.resolvedIP ?? ""),\(r.status.rawValue),\(r.sent),\(r.received),\(loss)%,\(lat),\(avg),\(err)\n"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPinginfo_\(Int(Date().timeIntervalSince1970)).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
