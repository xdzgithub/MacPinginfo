import Foundation
import Darwin

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

    private var processes: [String: Process] = [:]
    private var handlers: [String: DispatchSourceRead] = [:]
    private var outputBuffers: [String: String] = [:]
    private let resolver = DNSResolver()

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
        for (_, proc) in processes {
            proc.terminate()
        }
        processes.removeAll()
        handlers.removeAll()
        outputBuffers.removeAll()
    }

    func clear() {
        stop()
        results = []
    }

    // MARK: - Persistent ping process

    private func spawnStreamingPing(for r: ResolvedHost) {
        guard let _ = r.ipv4 else { return }

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
                // EOF — process ended
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

    private func handleProcessEnd(hostname: String) {
        // If the process unexpectedly exits while running, mark current result as timeout.
        guard isRunning, let proc = processes[hostname] else { return }
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
        // Skip summary/statistics lines
        if line.hasPrefix("---")          { return false }
        if line.hasPrefix("PING ")        { return false }
        if line.hasPrefix("ping: ")       { return true }
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
                                   error: error, offlineThreshold: 2)
        }
    }

    // MARK: - CSV export

    func exportCSV() -> URL? {
        var csv = "Hostname,ResolvedIP,Status,Sent,Received,Lost,Loss%,LastLatency,AvgLatency,LastError\n"
        for r in results {
            let loss = r.sent > 0 ? String(format: "%.1f", r.packetLoss) : "0.0"
            let lat  = r.lastLatency.map   { String(format: "%.2f", $0) } ?? ""
            let avg  = r.averageLatency.map { String(format: "%.2f", $0) } ?? ""
            let err  = (r.lastError ?? "").replacingOccurrences(of: ",", with: ";")
            csv += "\(r.hostname),\(r.resolvedIP ?? ""),\(r.status.rawValue),\(r.sent),\(r.received),\(r.lost),\(loss)%,\(lat),\(avg),\(err)\n"
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
