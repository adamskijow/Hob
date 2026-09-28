// SPDX-License-Identifier: MIT
import HobAppExperience
import SwiftUI

@main
struct HobPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            // The device benchmark owns isolated stores and mock integrations.
            // Do not open the user's workspace while hosting those tests.
            #if DEBUG
            if ProcessInfo.processInfo.environment["HOB_UI_TEST_SCENARIO"] != nil {
                HobUITestWorkspace()
            } else if ProcessInfo.processInfo.environment["HOB_MESSAGE_BENCHMARK"] == "1" {
                Color.clear
            } else {
                HobWorkspaceView()
            }
            #else
            HobWorkspaceView()
            #endif
        }
    }
}
