import Foundation

struct HostFormatter {
    static func format(_ input: String) -> String {
        let separators = CharacterSet(charactersIn: ",\n\r\t;| ")
        let rawHosts = input
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [String] = []

        for host in rawHosts {
            let normalized = host.lowercased()
            if !seen.contains(normalized) {
                seen.insert(normalized)
                result.append(host)
            }
        }

        return result.joined(separator: "\n")
    }
}
