import SwiftUI

@available(macOS 12.0, *)
@main
struct MenuBarBadgesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

