import Testing
import AppKit
import UserNotifications
@testable import NotiBar

@MainActor
private final class NotificationSpy: AppDelegate {
    var delivered: [[Application]] = []
    override func postIncreaseNotification(for apps: [Application]) {
        delivered.append(apps)
    }
}

@Suite(.serialized)
@MainActor
struct NotiBarTests {
    // Restore preferences because the production setters persist immediately.
    private func withDelegate(_ body: (NotificationSpy) async throws -> Void) async rethrows {
        let keys = ["displayMode", "autoRefreshEnabled", "refreshInterval"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let delegate = NotificationSpy()
        delegate.autoRefreshEnabled = false
        delegate.soundOnIncrease = false
        delegate.notificationOnIncrease = false
        delegate.fetchDockApplications = { [] }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        delegate.statusBarItem = item
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            NSStatusBar.system.removeStatusItem(item)
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        }
        try await body(delegate)
    }

    @Test(arguments: [DisplayMode.popover, .direct])
    func notificationsCoverIncreasesAndNewApps(mode: DisplayMode) async {
        await withDelegate { delegate in
            delegate.displayMode = mode
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            delegate.notificationOnIncrease = true
            delegate.blinkingEnabled = false
            delegate.fetchDockApplications = { [Application(name: "Example", badgeCount: 1)] }
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            #expect(delegate.delivered.count == 1)
            delegate.fetchDockApplications = { [Application(name: "Example", badgeCount: 2)] }
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            #expect(delegate.delivered.count == 2)
            #expect(delegate.delivered.last?.first?.badgeCount == 2)
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            #expect(delegate.delivered.count == 2)
            delegate.notificationOnIncrease = false
            delegate.fetchDockApplications = { [Application(name: "Example", badgeCount: 3)] }
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            #expect(delegate.delivered.count == 2)
        }
    }

    @Test func disabledNotificationsBlockManualTests() {
        let delegate = AppDelegate()
        delegate.notificationOnIncrease = false
        delegate.sendTestNotification()
        #expect(!delegate.isTestingNotification)
        #expect(delegate.notificationTestResult == "Turn on System notifications before sending a test.")
    }

    @Test func previewInitializationIsSafe() {
        let delegate = AppDelegate()
        delegate.togglePopover(nil)
        delegate.updateMenuBarDisplay()
        #expect(delegate.popover == nil)
        #expect(!delegate.isRefreshing)
    }

    @Test func existingBadgesFillIconWithoutAlerting() async throws {
        try await withDelegate { delegate in
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            let outline = try #require(delegate.statusBarItem.button?.image)
            delegate.fetchDockApplications = { [Application(name: "Example", badgeCount: 3)] }
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            let filled = try #require(delegate.statusBarItem.button?.image)
            #expect(filled !== outline)
            #expect(filled.isTemplate)
            #expect(delegate.statusBarItem.button?.contentTintColor == nil)
            delegate.fetchDockApplications = { [] }
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            #expect(delegate.statusBarItem.button?.image === outline)
        }
    }

    @Test func firstScanIsQuietAndLaterIncreaseAlerts() async {
        await withDelegate { delegate in
            delegate.fetchDockApplications = { [Application(name: "Test App", badgeCount: 3)] }
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            #expect(delegate.applicationsWithBadges.first?.badgeCount == 3)
            #expect(!delegate.pendingIconAlert)
            #expect(delegate.lastIncreaseSummary == nil)
            delegate.fetchDockApplications = { [Application(name: "Test App", badgeCount: 4)] }
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            #expect(delegate.pendingIconAlert)
            #expect(delegate.lastIncreaseSummary?.contains("+1") == true)
        }
    }

    @Test func failedScansPreserveSnapshotAndBackOff() async {
        await withDelegate { delegate in
            delegate.refreshInterval = 5
            delegate.fetchDockApplications = { [Application(name: "Test App", badgeCount: 3)] }
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            delegate.fetchDockApplications = { throw DockScanError.invalidResponse }
            for _ in 0..<10 {
                delegate.updateMenuBarDisplay()
                await delegate.waitForRefresh()
            }
            #expect(delegate.applicationsWithBadges.first?.badgeCount == 3)
            #expect(delegate.refreshError != nil)
            #expect(delegate.effectiveRefreshInterval == 300)
            delegate.fetchDockApplications = { [Application(name: "Test App", badgeCount: 3)] }
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            #expect(delegate.refreshError == nil)
            #expect(delegate.effectiveRefreshInterval == 5)
            #expect(!delegate.pendingIconAlert)
        }
    }

    @Test func blinkKeepsWidthAndModeSwitchCancelsPulse() async throws {
        try await withDelegate { delegate in
            delegate.displayMode = .direct
            await delegate.waitForRefresh()
            let apps = [Application(name: "Mail", badgeCount: 12)]
            delegate.startBlinking(appsWithBadges: apps, newBadgeCounts: [apps[0].id: 12])
            let item = try #require(delegate.statusBarItem)
            let pulse = try #require(delegate.blinkingTimer)
            let width = item.length
            let title = item.button?.title
            for _ in 0..<6 {
                pulse.fire()
                #expect(item.length == width)
                #expect(item.button?.attributedTitle.string == title)
                #expect(item.button?.alignment == .center)
            }
            delegate.displayMode = .popover
            await delegate.waitForRefresh()
            #expect(delegate.blinkingTimer == nil)
            #expect(!pulse.isValid)
            #expect(item.button?.title == "")
            #expect(item.button?.image != nil)
            delegate.displayMode = .direct
            await delegate.waitForRefresh()
            #expect(item.button?.image == nil)
            #expect(item.button?.title.isEmpty == false)
        }
    }

    @Test func sleepPausesScansAndWakeResumes() async {
        await withDelegate { delegate in
            var scans = 0
            delegate.fetchDockApplications = { scans += 1; return [] }
            delegate.autoRefreshEnabled = true
            delegate.workspaceWillSleep()
            delegate.updateMenuBarDisplay()
            await delegate.waitForRefresh()
            #expect(scans == 0)
            #expect(delegate.timer == nil)
            delegate.workspaceDidWake()
            await delegate.waitForRefresh()
            #expect(scans == 1)
            #expect(delegate.timer?.isValid == true)
        }
    }
}
