// SPDX-License-Identifier: MIT
import Foundation
import ServiceManagement
#if canImport(HobAppCore)
import HobAppCore
#endif

@MainActor
final class BackgroundServiceController: ObservableObject {
    static let helperIdentifier = "com.josephadamski.hob.agent"

    @Published private(set) var state: BackgroundServiceState = .unknown
    @Published private(set) var lastError: String?
    let runtimeAvailable: Bool

    private let service: SMAppService

    init(
        service: SMAppService = .loginItem(identifier: helperIdentifier),
        runtimeAvailable: Bool = false
    ) {
        self.service = service
        self.runtimeAvailable = runtimeAvailable
        refresh()
    }

    var isDeliveryReady: Bool { runtimeAvailable && state.isApproved }

    func refresh() {
        state = Self.map(service.status)
    }

    func enable() {
        lastError = nil
        guard runtimeAvailable else {
            lastError = "Background delivery will unlock when the Hob runtime is connected."
            return
        }
        do {
            try service.register()
        } catch {
            lastError = "Hob could not register its background helper."
        }
        refresh()
        if state == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func disable() {
        lastError = nil
        do {
            try service.unregister()
        } catch {
            lastError = "Hob could not disable its background helper."
        }
        refresh()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> BackgroundServiceState {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
}
