// SPDX-License-Identifier: MIT
import Foundation
#if canImport(HobAppCore)
import HobAppCore
#endif
#if canImport(HobAppStorage)
import HobAppStorage
#endif

@MainActor
private final class AgentRuntime {
    private let healthURL: URL
    private let taskRuntime: DurableTaskRuntime

    init(healthURL: URL, taskRuntime: DurableTaskRuntime) {
        self.healthURL = healthURL
        self.taskRuntime = taskRuntime
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
        let storage = SharedStorage.system
        let healthURL = try storage.agentHealthURL()
        let taskRuntime = try DurableTaskRuntime(
            store: TaskStateStore(directoryURL: try storage.taskStateDirectory())
        )
        let runtime = AgentRuntime(healthURL: healthURL, taskRuntime: taskRuntime)
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
