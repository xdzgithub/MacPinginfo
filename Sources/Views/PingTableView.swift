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
        case .invalid: return .orange
        }
    }
}

struct PingTableView: View {
    @ObservedObject var engine: PingEngine

    private let columnSpacing: CGFloat = 18

    var body: some View {
        ScrollView(.vertical) {
            Grid(alignment: .leading, horizontalSpacing: columnSpacing, verticalSpacing: 4) {
                headerRow

                GridRow {
                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 1)
                        .gridCellColumns(9)
                }

                ForEach(engine.results) { result in
                    dataRow(result)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .animation(.easeInOut(duration: 0.25), value: engine.results.map(\.id))
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Header

    private var headerRow: some View {
        GridRow {
            Button {
                engine.togglePinOnlineToTop()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(engine.pinOnlineToTop ? Color.green : Color.gray)
                    Text(L10n.string("Table.Status"))
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help(L10n.string("Table.PinHelp"))
            .gridColumnAlignment(.leading)

            headerText("Table.Hostname", alignment: .leading)
            headerText("Table.Sent", alignment: .trailing)
            headerText("Table.Received", alignment: .trailing)
            headerText("Table.Lost", alignment: .trailing)
            headerText("Table.PacketLoss", alignment: .trailing)
            headerText("Table.LastLatency", alignment: .trailing)
            headerText("Table.AvgLatency", alignment: .trailing)
            headerText("Table.Error", alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func headerText(_ key: String, alignment: HorizontalAlignment) -> some View {
        Text(L10n.string(key))
            .gridColumnAlignment(alignment)
    }

    // MARK: - Rows

    private func dataRow(_ result: PingResult) -> some View {
        GridRow {
            HStack(spacing: 6) {
                StatusIndicator(status: result.status)
                Text(result.status.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .gridColumnAlignment(.leading)

            Text(result.hostname)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(result.isInvalid ? Color.orange : Color.primary)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)

            Text("\(result.sent)")
                .monospacedDigit()
                .gridColumnAlignment(.trailing)

            Text("\(result.received)")
                .monospacedDigit()
                .gridColumnAlignment(.trailing)

            Text("\(result.lost)")
                .monospacedDigit()
                .foregroundStyle(result.lost > 0 ? Color.orange : Color.primary)
                .gridColumnAlignment(.trailing)

            Text(String(format: "%.1f%%", result.packetLoss))
                .monospacedDigit()
                .foregroundStyle(packetLossColor(result.packetLoss))
                .gridColumnAlignment(.trailing)

            latencyText(result.lastLatency)
                .gridColumnAlignment(.trailing)

            latencyText(result.averageLatency)
                .gridColumnAlignment(.trailing)

            errorText(result.lastError)
                .gridColumnAlignment(.leading)
        }
    }

    @ViewBuilder
    private func latencyText(_ value: Double?) -> some View {
        if let value {
            Text(String(format: "%.2f", value))
                .monospacedDigit()
        } else {
            Text("-")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func errorText(_ error: String?) -> some View {
        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Text("-")
                .foregroundStyle(.secondary)
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
