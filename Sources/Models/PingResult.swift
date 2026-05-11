import Foundation

enum PingStatus: String {
    case waiting
    case online
    case offline

    var localized: String {
        switch self {
        case .waiting: return L10n.string("Status.Waiting")
        case .online: return L10n.string("Status.Online")
        case .offline: return L10n.string("Status.Offline")
        }
    }
}

private let maxLatencyHistory = 1000

struct PingResult: Identifiable, Equatable {
    let id = UUID()
    var hostname: String
    var status: PingStatus = .waiting
    var sent: Int = 0
    var received: Int = 0
    var lastLatency: Double? = nil
    var averageLatency: Double? = nil
    var lastError: String? = nil
    private var latencyBuffer: [Double] = []

    init(hostname: String, status: PingStatus = .waiting) {
        self.hostname = hostname
        self.status = status
    }

    var packetLoss: Double {
        guard sent > 0 else { return 0.0 }
        return Double(sent - received) / Double(sent) * 100.0
    }

    mutating func recordPing(success: Bool, latency: Double?, error: String?) {
        sent += 1
        if success, let ms = latency {
            received += 1
            lastLatency = ms
            lastError = nil
            latencyBuffer.append(ms)
            if latencyBuffer.count > maxLatencyHistory {
                latencyBuffer.removeFirst(latencyBuffer.count - maxLatencyHistory)
            }
            averageLatency = latencyBuffer.reduce(0, +) / Double(latencyBuffer.count)
            status = .online
        } else {
            lastLatency = nil
            lastError = error
            if sent == 1 {
                status = .offline
            }
        }
    }

    mutating func reset() {
        status = .waiting
        sent = 0
        received = 0
        lastLatency = nil
        averageLatency = nil
        lastError = nil
        latencyBuffer = []
    }
}
