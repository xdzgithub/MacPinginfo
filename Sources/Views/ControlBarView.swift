import SwiftUI
import UniformTypeIdentifiers

struct ControlBarView: View {
    @ObservedObject var engine: PingEngine
    @Binding var hostInput: String
    @Binding var pingInterval: TimeInterval
    @Binding var resolveHostnamesViaIPv6: Bool

    @State private var exportFailed = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                if engine.isRunning {
                    engine.stop()
                } else {
                    engine.pingInterval = pingInterval
                    engine.resolveHostnamesViaIPv6 = resolveHostnamesViaIPv6
                    engine.start(hosts: parsedHosts)
                    fitWindowToTable()
                }
            }) {
                // Lay out both labels so the button keeps one width in every
                // state and locale; only one is visible. Otherwise the play/stop
                // glyph (and Start/Stop text) width difference shifts the
                // clear/export/interval controls to its right on each toggle.
                ZStack {
                    Label(L10n.string("Button.Start"), systemImage: "play.fill")
                        .opacity(engine.isRunning ? 0 : 1)
                        .accessibilityHidden(engine.isRunning)
                    Label(L10n.string("Button.Stop"), systemImage: "stop.fill")
                        .opacity(engine.isRunning ? 1 : 0)
                        .accessibilityHidden(!engine.isRunning)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .green)
            .keyboardShortcut(engine.isRunning ? "s" : "r", modifiers: .command)

            Button(action: {
                engine.clear()
                hostInput = ""
            }) {
                Label(L10n.string("Button.Clear"), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("k", modifiers: .command)

            Button(action: exportCSV) {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(engine.results.isEmpty)
            .keyboardShortcut("e", modifiers: .command)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Text(L10n.string("Interval.Label"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("", selection: $pingInterval) {
                    ForEach(intervalOptions, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
            }
            .fixedSize()

            Toggle(L10n.string("Setting.ResolveHostnamesViaIPv6"), isOn: $resolveHostnamesViaIPv6)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.subheadline)
                .help(L10n.string("Setting.ResolveHostnamesViaIPv6Help"))
                .fixedSize()

            Spacer()

            Text(L10n.format("Pinging.Status", engine.results.filter { !$0.isInvalid }.count))
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(engine.isRunning ? 1 : 0)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 32)
        .alert(L10n.string("Export.FailedTitle"), isPresented: $exportFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(L10n.string("Export.FailedMessage"))
        }
    }

    /// Ask the user where to save, then write the CSV there.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = L10n.string("Export.PanelTitle")
        panel.nameFieldStringValue = "MacPinginfo_\(Self.timestamp()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !engine.exportCSV(to: url) {
            exportFailed = true
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    /// Set the window's width to fit the table's current content, so a Start
    /// always shows every column (full addresses included) without horizontal
    /// scrolling — narrow for all-IPv4 hosts, wider when IPv6 addresses appear.
    /// Deferred one runloop turn so the new rows are laid out first.
    private func fitWindowToTable() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
            let hostnames = engine.results.filter { !$0.isInvalid }.map(\.hostname)
            let resolved = engine.results.compactMap(\.resolvedIP)
            let target = PingTableView.fitWidth(hostnames: hostnames, resolvedIPs: resolved)
            var frame = window.frame
            guard abs(frame.size.width - target) > 1 else { return }
            frame.size.width = target
            window.setFrame(frame, display: true)
        }
    }

    private var intervalOptions: [(String, TimeInterval)] {
        [
            (L10n.string("Interval.Option1s"), 1.0),
            (L10n.string("Interval.Option2s"), 2.0),
            (L10n.string("Interval.Option5s"), 5.0),
            (L10n.string("Interval.Option10s"), 10.0),
        ]
    }

    private var parsedHosts: [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        return hostInput
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
