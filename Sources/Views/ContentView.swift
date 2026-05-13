import SwiftUI

struct ContentView: View {
    @StateObject private var engine = PingEngine()
    @State private var hostInput: String = ""
    @AppStorage("savedHosts") private var savedHosts: String = ""
    @State private var pingInterval: TimeInterval = 1.0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HostInputView(text: Binding(
                    get: { hostInput },
                    set: { hostInput = $0; savedHosts = $0 }
                )) {
                    formatInput()
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .onAppear {
                if !savedHosts.isEmpty {
                    hostInput = savedHosts
                }
            }

            Divider()

            ControlBarView(engine: engine, hostInput: $hostInput, pingInterval: $pingInterval)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if engine.results.isEmpty {
                emptyStateView
            } else {
                PingTableView(results: engine.results)
                    .padding(0)
            }
        }
        .frame(minWidth: 700, minHeight: 400)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(L10n.string("Empty.Title"))
                .font(.title3)
                .foregroundColor(.secondary)
            Text(L10n.string("Empty.Subtitle"))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func formatInput() {
        hostInput = HostFormatter.format(hostInput)
    }
}
