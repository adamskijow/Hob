// SPDX-License-Identifier: MIT
import Foundation

public struct OperationalHealth: Equatable, Sendable {
    public let isReady: Bool
    public let summary: String

    public init(isReady: Bool, summary: String) {
        self.isReady = isReady
        self.summary = summary
    }

    public static func summarize(
        exitCode: Int32,
        standardOutput: String,
        standardError: String
    ) -> OperationalHealth {
        let lines = (standardOutput + "\n" + standardError)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if let failure = lines.first(where: {
            $0.contains("FAIL")
                || $0.contains("refused")
                || $0.contains("config error")
        }) {
            return OperationalHealth(isReady: false, summary: failure)
        }
        if lines.contains(where: { $0.contains("token=none") }) {
            return OperationalHealth(
                isReady: false,
                summary: "Telegram needs a bot token before Hob can deliver."
            )
        }
        if lines.contains(where: { $0.contains("owner=unpaired") }) {
            return OperationalHealth(
                isReady: false,
                summary: "Send /start for your ID, then run scripts/hobctl pair ID."
            )
        }
        if lines.contains(where: { $0.contains("WARN queues:") }) {
            return OperationalHealth(
                isReady: false,
                summary: "Hob has durable work waiting to process or send."
            )
        }
        guard exitCode == 0 else {
            return OperationalHealth(
                isReady: false,
                summary: "Hob found a problem. Open the log for details."
            )
        }
        return OperationalHealth(
            isReady: true,
            summary: "Database, queues, Telegram, and local model are ready."
        )
    }
}
