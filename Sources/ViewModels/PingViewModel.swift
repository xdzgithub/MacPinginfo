import Foundation
import SwiftUI

@MainActor
final class PingViewModel: ObservableObject {
    @Published var hostInput: String = ""

    func formatHostInput() {
        hostInput = HostFormatter.format(hostInput)
    }
}
