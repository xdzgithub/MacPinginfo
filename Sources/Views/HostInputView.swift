import SwiftUI

struct HostInputView: View {
    @Binding var text: String
    var onFormat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.string("Input.Label"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: onFormat) {
                    Label(L10n.string("Button.Format"), systemImage: "text.alignleft")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80, idealHeight: 100, maxHeight: 120)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
        }
    }
}
