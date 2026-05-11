import SwiftUI

struct ControlBarView: View {
    @ObservedObject var pingManager: PingManager
    @Binding var hostInput: String
    @Binding var pingInterval: TimeInterval

    var body: some View {
        HStack(spacing: 16) {
            Button(action: {
                if pingManager.isRunning {
                    pingManager.stopPinging()
                } else {
                    pingManager.pingInterval = pingInterval
                    pingManager.startPinging(hosts: parsedHosts)
                }
            }) {
                Label(
                    pingManager.isRunning ? L10n.string("Button.Stop") : L10n.string("Button.Start"),
                    systemImage: pingManager.isRunning ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(pingManager.isRunning ? .red : .green)
            .keyboardShortcut(pingManager.isRunning ? "s" : "r", modifiers: .command)

            Button(action: {
                pingManager.clearResults()
                hostInput = ""
            }) {
                Label(L10n.string("Button.Clear"), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("k", modifiers: .command)

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
                .frame(width: 140)
            }

            Spacer()

            if pingManager.isRunning {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text(L10n.format("Pinging.Status", pingManager.results.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 4)
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
