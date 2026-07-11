// SPDX-License-Identifier: MIT
import Foundation
#if canImport(HobAppCore)
import HobAppCore
#endif

@MainActor
final class FoundationModelController: ObservableObject {
    @Published private(set) var state: ModelReadinessState = .notChecked

    private let bridgeURL: URL

    init(bundleURL: URL = Bundle.main.bundleURL) {
        bridgeURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent("HobAgent.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("HobFoundationBridge")
    }

    func check() {
        guard state != .checking else { return }
        guard FileManager.default.isExecutableFile(atPath: bridgeURL.path) else {
            state = .toolMissing
            return
        }
        state = .checking
        let executableURL = bridgeURL
        Task.detached {
            let result = Self.runProbe(executableURL: executableURL)
            await MainActor.run {
                self.state = result
            }
        }
    }

    nonisolated private static func runProbe(executableURL: URL) -> ModelReadinessState {
        let requestID = UUID().uuidString
        let request: [String: Any] = [
            "version": 1,
            "requestID": requestID,
            "command": "probe",
        ]
        guard let input = try? JSONSerialization.data(withJSONObject: request) else {
            return .invalidResponse
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let inputPipe = Pipe()
        process.executableURL = executableURL
        process.standardInput = inputPipe
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(input)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            return .unavailable
        }

        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return .timedOut
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 100_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1,
              object["requestID"] as? String == requestID,
              let status = object["status"] as? String else {
            return .invalidResponse
        }
        return status == "available" ? .available : .unavailable
    }
}
