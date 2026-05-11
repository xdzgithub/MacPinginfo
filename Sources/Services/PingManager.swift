import Foundation

struct PingResponse {
    let hostname: String
    let success: Bool
    let latency: Double?
    let error: String?
}

@MainActor
final class PingManager: ObservableObject {
    @Published var results: [PingResult] = []
    @Published var isRunning: Bool = false
    @Published var pingInterval: TimeInterval = 1.0

    private var tasks: [String: Task<Void, Never>] = [:]

    func startPinging(hosts: [String]) {
        guard !isRunning else { return }
        guard !hosts.isEmpty else { return }

        results = hosts.map { PingResult(hostname: $0, status: .waiting) }
        isRunning = true

        for host in hosts {
            let task = Task { [weak self] in
                guard let self = self else { return }
                await self.runPing(host: host)
            }
            tasks[host] = task
        }
    }

    func stopPinging() {
        isRunning = false
        for (_, task) in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }

    func clearResults() {
        stopPinging()
        results = []
    }

    private func runPing(host: String) async {
        while isRunning && !Task.isCancelled {
            let response = await ping(host: host)
            guard isRunning else { return }
            applyResult(response)
            try? await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
        }
    }

    private nonisolated func ping(host: String) async -> PingResponse {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.doPing(host: host)
                continuation.resume(returning: result)
            }
        }
    }

    private nonisolated static func doPing(host: String) -> PingResponse {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "2", host]
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return PingResponse(hostname: host, success: false, latency: nil,
                              error: "run failed: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = out + err

        let exitCode = process.terminationStatus
        let latency = parseLatency(combined)
        let success = exitCode == 0

        return PingResponse(
            hostname: host,
            success: success,
            latency: latency,
            error: success ? nil : parseError(combined, exitCode: exitCode)
        )
    }

    private nonisolated static func parseLatency(_ output: String) -> Double? {
        guard let regex = try? NSRegularExpression(
            pattern: #"time[=<]\s*([0-9]+\.?[0-9]*)\s*(?:ms|msec)?"#,
            options: .caseInsensitive
        ) else { return nil }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        if let match = regex.firstMatch(in: output, options: [], range: range),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: output),
           let value = Double(String(output[r])), value >= 0 {
            return value
        }
        return nil
    }

    private nonisolated static func parseError(_ output: String, exitCode: Int32) -> String {
        switch exitCode {
        case 68:  return "DNS resolution failed"
        case 69:  return "Network unreachable"
        case 2:   return "Request timeout"
        default:  break
        }
        if output.contains("Unknown host") { return "DNS resolution failed" }
        if output.contains("no route")    { return "Network unreachable" }
        if output.contains("100%")        { return "100% packet loss" }
        if output.contains("0 packets received") { return "no reply" }
        return "exit:\(exitCode)"
    }

    private func applyResult(_ response: PingResponse) {
        guard isRunning else { return }
        if let idx = results.firstIndex(where: { $0.hostname == response.hostname }) {
            results[idx].recordPing(
                success: response.success,
                latency: response.latency,
                error: response.error
            )
        }
    }
}
