// SPDX-License-Identifier: MIT
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        refresh()
        if status == .notRegistered { enable() }
    }

    var isEnabled: Bool { status == .enabled }

    var guidance: String {
        switch status {
        case .enabled:
            return "Hob opens in the menu bar when you sign in."
        case .requiresApproval:
            return "Allow Hob in Login Items to start it after a restart."
        case .notFound:
            return "Move Hob to Applications, then turn startup on again."
        case .notRegistered:
            return "Hob will stay off after a restart."
        @unknown default:
            return "Check startup again."
        }
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    func enable() {
        lastError = nil
        do {
            try service.register()
        } catch {
            lastError = "Hob could not turn on startup."
        }
        refresh()
    }

    func disable() {
        lastError = nil
        do {
            try service.unregister()
        } catch {
            lastError = "Hob could not turn off startup."
        }
        refresh()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
