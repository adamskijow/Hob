// SPDX-License-Identifier: MIT
import Foundation
#if canImport(HobAppCore)
import HobAppCore
#endif

@MainActor
private final class AgentRuntime {
    private let healthURL: URL

    init(healthURL: URL) {
        self.healthURL = healthURL
    }

    func writeHeartbeat() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let health = AgentHealth(state: "foundation", updatedAt: Date())
        guard let data = try? encoder.encode(health) else { return }
        try? data.write(to: healthURL, options: [.atomic])
    }
}

@main
private struct HobAgent {
    @MainActor
    static func main() throws {
        let healthURL = try SharedStorage.system.agentHealthURL()
        let runtime = AgentRuntime(healthURL: healthURL)
        runtime.writeHeartbeat()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak runtime] _ in
            Task { @MainActor in
                runtime?.writeHeartbeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
    }
}

