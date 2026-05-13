import SwiftUI

struct ControlBarView: View {
    @ObservedObject var engine: PingEngine
    @Binding var hostInput: String
    @Binding var pingInterval: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                if engine.isRunning {
                    engine.stop()
                } else {
                    engine.pingInterval = pingInterval
                    engine.start(hosts: parsedHosts)
                }
            }) {
                Label(
                    engine.isRunning ? L10n.string("Button.Stop") : L10n.string("Button.Start"),
                    systemImage: engine.isRunning ? "stop.fill" : "play.fill"
                )
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

            Button(action: {
                if let url = engine.exportCSV() {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }
            }) {
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

            Spacer()

            Text(L10n.format("Pinging.Status", engine.results.count))
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(engine.isRunning ? 1 : 0)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 32)
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
