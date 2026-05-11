import SwiftUI

struct StatusIndicator: View {
    let status: PingStatus

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        switch status {
        case .waiting: return .gray
        case .online: return .green
        case .offline: return .red
        }
    }
}

struct PingTableView: View {
    let results: [PingResult]

    var body: some View {
        Table(results) {
            TableColumn(L10n.string("Table.Status")) { result in
                HStack(spacing: 6) {
                    StatusIndicator(status: result.status)
                    Text(result.status.localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 80, ideal: 90)

            TableColumn(L10n.string("Table.Hostname")) { result in
                Text(result.hostname)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 150, ideal: 200)

            TableColumn(L10n.string("Table.Sent")) { result in
                Text("\(result.sent)")
            }
            .width(min: 50, ideal: 60)

            TableColumn(L10n.string("Table.Received")) { result in
                Text("\(result.received)")
            }
            .width(min: 60, ideal: 80)

            TableColumn(L10n.string("Table.PacketLoss")) { result in
                Text(String(format: "%.1f%%", result.packetLoss))
                    .foregroundColor(packetLossColor(result.packetLoss))
            }
            .width(min: 70, ideal: 90)

            TableColumn(L10n.string("Table.LastLatency")) { result in
                if let latency = result.lastLatency {
                    Text(String(format: "%.2f", latency))
                } else {
                    Text("-")
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 100, ideal: 120)

            TableColumn(L10n.string("Table.AvgLatency")) { result in
                if let avg = result.averageLatency {
                    Text(String(format: "%.2f", avg))
                } else {
                    Text("-")
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 100, ideal: 120)

            TableColumn(L10n.string("Table.Error")) { result in
                if let error = result.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("-")
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 100, ideal: 150)
        }
    }

    private func packetLossColor(_ loss: Double) -> Color {
        if loss == 0 {
            return .green
        } else if loss < 50 {
            return .orange
        } else {
            return .red
        }
    }
}
