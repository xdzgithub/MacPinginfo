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

    private static let columnSpacing: CGFloat = 14
    private static let horizontalPadding: CGFloat = 12

    /// The value columns have fixed widths, so changing counters, latency and
    /// loss never resize anything. The Hostname/IP and Resolved IP columns are
    /// flexible: they grow to absorb spare width when the window is enlarged and
    /// shrink toward their floor when it is narrowed, so resizing reflows the
    /// table rather than clipping it. Their floor is small enough for plain IPv4,
    /// so an all-IPv4 table is not forced wide; a full IPv6 address still expands
    /// the column on its own.
    private enum Col {
        static let status: CGFloat = 60
        static let hostnameFloor: CGFloat = 110   // fits an IPv4 literal comfortably
        static let family: CGFloat = 42
        static let resolvedIPFloor: CGFloat = 96  // fits an IPv4 literal
        static let count: CGFloat = 46            // Sent / Received / Lost
        static let loss: CGFloat = 60
        static let latency: CGFloat = 54          // Last / Avg
        static let error: CGFloat = 150

        static let fixedSum: CGFloat =
            status + family + count * 3 + loss + latency * 2 + error
    }

    /// Width that fits the given hosts at their full value. Sized from the actual
    /// content, so a run of plain IPv4 addresses produces a narrow window while a
    /// full IPv6 address widens the two address columns. Callers size the window
    /// to this on Start so every column is visible without truncation.
    static func fitWidth(hostnames: [String], resolvedIPs: [String] = []) -> CGFloat {
        let hostFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let ipFont = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                                                 weight: .regular)
        func width(_ s: String, _ f: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: f]).width
        }
        let hostText = hostnames.map { width($0, hostFont) }.max() ?? 0
        let ipText = (hostnames + resolvedIPs).map { width($0, ipFont) }.max() ?? 0

        // Header ("主机名 / IP" / "解析 IP") is the floor; a few points of slack.
        let hostname = max(Col.hostnameFloor, ceil(hostText) + 8)
        let resolvedIP = max(Col.resolvedIPFloor, ceil(ipText) + 8)
        let spacing = columnSpacing * 10          // 11 columns → 10 gaps
        return Col.fixedSum + hostname + resolvedIP + spacing + horizontalPadding * 2
    }

    var body: some View {
        // Vertical for rows; horizontal only kicks in when the window is narrower
        // than the table's minimum, so a cramped window scrolls to the columns
        // instead of clipping them (at normal sizes the flexible columns fill the
        // width and no horizontal scroller appears).
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: Self.columnSpacing, verticalSpacing: 4) {
                headerRow

                GridRow {
                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 1)
                        .gridCellColumns(11)
                }

                ForEach(engine.results) { result in
                    dataRow(result)
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 10)
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
            .frame(width: Col.status, alignment: .leading)

            flexibleHeaderText("Table.Hostname", minWidth: Col.hostnameFloor)
            headerText("Table.Family", width: Col.family, align: .leading)
            flexibleHeaderText("Table.ResolvedIP", minWidth: Col.resolvedIPFloor)
            headerText("Table.Sent", width: Col.count, align: .trailing)
            headerText("Table.Received", width: Col.count, align: .trailing)
            headerText("Table.Lost", width: Col.count, align: .trailing)
            headerText("Table.PacketLoss", width: Col.loss, align: .trailing)
            headerText("Table.LastLatency", width: Col.latency, align: .trailing)
            headerText("Table.AvgLatency", width: Col.latency, align: .trailing)
            headerText("Table.Error", width: Col.error, align: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func headerText(_ key: String, width: CGFloat, align: Alignment) -> some View {
        Text(L10n.string(key))
            .frame(width: width, alignment: align)
    }

    private func flexibleHeaderText(_ key: String, minWidth: CGFloat) -> some View {
        Text(L10n.string(key))
            .frame(minWidth: minWidth, maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    private func dataRow(_ result: PingResult) -> some View {
        GridRow {
            HStack(spacing: 6) {
                StatusIndicator(status: result.status)
                Text(result.status.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: Col.status, alignment: .leading)

            // Flexible: fills spare width, truncates only when the window is
            // narrower than a full IPv6 literal.
            Text(result.hostname)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(result.isInvalid ? Color.orange : Color.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(result.hostname)
                .frame(minWidth: Col.hostnameFloor, maxWidth: .infinity, alignment: .leading)

            familyText(result.family)
                .frame(width: Col.family, alignment: .leading)

            resolvedIPText(result.resolvedIP)
                .frame(minWidth: Col.resolvedIPFloor, maxWidth: .infinity, alignment: .leading)

            Text("\(result.sent)")
                .monospacedDigit()
                .frame(width: Col.count, alignment: .trailing)

            Text("\(result.received)")
                .monospacedDigit()
                .frame(width: Col.count, alignment: .trailing)

            Text("\(result.lost)")
                .monospacedDigit()
                .foregroundStyle(result.lost > 0 ? Color.orange : Color.primary)
                .frame(width: Col.count, alignment: .trailing)

            Text(String(format: "%.1f%%", result.packetLoss))
                .monospacedDigit()
                .foregroundStyle(packetLossColor(result.packetLoss))
                .frame(width: Col.loss, alignment: .trailing)

            latencyText(result.lastLatency)
                .frame(width: Col.latency, alignment: .trailing)

            latencyText(result.averageLatency)
                .frame(width: Col.latency, alignment: .trailing)

            errorText(result.lastError)
                .frame(width: Col.error, alignment: .leading)
        }
    }

    @ViewBuilder
    private func familyText(_ family: HostAddressFamily?) -> some View {
        if let family {
            Text(family.displayName)
                .font(.caption)
                .foregroundStyle(family == .ipv6 ? Color.purple : Color.teal)
        } else {
            Text("-")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resolvedIPText(_ ip: String?) -> some View {
        if let ip {
            Text(ip)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(ip)
        } else {
            Text("-")
                .foregroundStyle(.secondary)
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
                .lineLimit(1)
                .truncationMode(.tail)
                .help(error)
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
