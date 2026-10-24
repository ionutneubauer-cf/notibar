import SwiftUI
import AppKit
import ApplicationServices
import Combine
import UserNotifications
import ServiceManagement

@available(macOS 12.0, *)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    var statusBarItem: NSStatusItem!
    var popover: NSPopover?
    @Published var displayMode: DisplayMode = .popover {
        didSet {
            guard displayMode != oldValue else { return }
            UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode")
            // A text-mode pulse must not overwrite the icon after switching modes.
            let wasBlinking = blinkingTimer != nil
            blinkingTimer?.invalidate()
            blinkingTimer = nil
            blinkContext = nil
            isBlinking = false
            blinkCounter = 0
            if statusBarItem != nil {
                if wasBlinking { setupTimer() }
                updateMenuBarDisplay()
            }
        }
    }
    // Apply side effects after assignment so they read the new settings.
    @Published var autoRefreshEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(autoRefreshEnabled, forKey: "autoRefreshEnabled")
            if statusBarItem != nil { setupTimer() }
        }
    }
    @Published var refreshInterval: Double = 5.0 {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            if statusBarItem != nil { setupTimer() }
        }
    }
    @Published var blinkingEnabled: Bool = true
    @Published var lastIncreaseSummary: String? = nil
    @Published var soundOnIncrease: Bool = true
    @Published private(set) var notificationStatus = "Checking…"
    @Published private(set) var notificationTestResult: String?
    @Published private(set) var isTestingNotification = false
    @Published private(set) var notificationError: String?
    private var notificationGeneration = 0
    @Published var notificationOnIncrease: Bool = true {
        didSet {
            guard notificationOnIncrease != oldValue else { return }
            notificationGeneration += 1
            if !notificationOnIncrease && notificationsSupported {
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            }
        }
    }
    @Published var popoverBannerOnIncrease: Bool = true
    @Published var showSearchBar: Bool = true
    @Published var menuBarSummaryEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(menuBarSummaryEnabled, forKey: "menuBarSummaryEnabled")
            updateMenuBarDisplay()
        }
    }
    @Published var menuBarSummaryLimit: Int = 2 {
        didSet {
            let clamped = max(1, min(5, menuBarSummaryLimit))
            if menuBarSummaryLimit != clamped {
                menuBarSummaryLimit = clamped
                return
            }
            UserDefaults.standard.set(menuBarSummaryLimit, forKey: "menuBarSummaryLimit")
            updateMenuBarDisplay()
        }
    }
    @Published var alarmSoundName: String = "Glass"
    @Published var accessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published var automationPermissionStatus: AutomationPermissionStatus = .unknown
    @Published var blinkColorName: String = "systemGray"
    @Published var notificationIcon: String = "📢"
    @Published private(set) var applicationsWithBadges: [Application] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastSuccessfulRefresh: Date?
    @Published private(set) var refreshError: String?
    @Published private(set) var loginItemEnabled = false
    @Published private(set) var loginItemNeedsApproval = false
    @Published private(set) var loginItemError: String?
    private(set) var consecutiveScanFailures = 0
    private(set) var isSleeping = false
    private var hasBaseline = false
    var effectiveRefreshInterval: TimeInterval {
        min(300, max(1, refreshInterval) * pow(2, Double(min(consecutiveScanFailures, 8))))
    }
    private var refreshTask: Task<Void, Never>?
    private let applicationCatalog = ApplicationCatalog()
    var fetchDockApplications: () async throws -> [Application] = {
        try await getDockApplications()
    }
    private var settingsWindowController: NSWindowController?
    var previousBadgeCounts: [String: Int] = [:]
    var blinkingTimer: Timer?
    var isBlinking = false
    var blinkCounter = 0
    var timer: Timer?
    var pendingIconAlert: Bool = false
    var accessibilityPollTimer: Timer?
    var accessibilityPollAttempts: Int = 0
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private struct BlinkContext {
        let fullTitle: String
        let newBadgeCounts: [String: Int]
        let maxBlinkCount: Int
    }
    private var blinkContext: BlinkContext?
    private var permissionMonitorTimer: Timer?
    // Removed blinking support for simpler persistent red indicator
    private var cancellables = Set<AnyCancellable>()
    // Cache symbols for fast toggling
    private var iconNormal: NSImage?
    private var iconAlert: NSImage?
    @Published var isSettingsPresented: Bool = false
    private var notificationsSupported: Bool {
        // UserNotifications needs a proper app bundle; skip when running bare executable
        if Bundle.main.bundleIdentifier == nil { return false }
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app"
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Test hosts must not start real Dock scans or request permissions.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if notificationsSupported { UNUserNotificationCenter.current().delegate = self }
        loadSettings()
        refreshLoginItemStatus()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(workspaceWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(workspaceDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateMenuBarDisplay()

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: ContentView().environmentObject(self))
        popover.behavior = .transient
        popover.delegate = self
        self.popover = popover

        // Ensure the status bar button action targets this delegate
        statusBarItem.button?.target = self
        statusBarItem.button?.action = #selector(togglePopover(_:))

        // displayMode updates handled in didSet for immediate UI changes
        
        $blinkingEnabled
            .sink { value in
                UserDefaults.standard.set(value, forKey: "blinkingEnabled")
            }
            .store(in: &cancellables)
        $blinkColorName
            .sink { value in
                UserDefaults.standard.set(value, forKey: "blinkColorName")
            }
            .store(in: &cancellables)

        $isSettingsPresented
            .sink { [weak self] shown in
                guard let self = self, self.popover != nil else { return }
                self.popover?.behavior = shown ? .applicationDefined : .transient
            }
            .store(in: &cancellables)

        $soundOnIncrease
            .sink { value in
                UserDefaults.standard.set(value, forKey: "soundOnIncrease")
            }
            .store(in: &cancellables)

        $notificationOnIncrease
            .sink { value in
                UserDefaults.standard.set(value, forKey: "notificationOnIncrease")
            }
            .store(in: &cancellables)
        $notificationIcon
            .sink { value in
                UserDefaults.standard.set(value, forKey: "notificationIcon")
            }
            .store(in: &cancellables)

        $popoverBannerOnIncrease
            .sink { value in
                UserDefaults.standard.set(value, forKey: "popoverBannerOnIncrease")
            }
            .store(in: &cancellables)

        $alarmSoundName
            .sink { value in
                UserDefaults.standard.set(value, forKey: "alarmSoundName")
            }
            .store(in: &cancellables)

        $showSearchBar
            .sink { value in
                UserDefaults.standard.set(value, forKey: "showSearchBar")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name("RefreshData"))
            .sink { [weak self] _ in
                self?.updateMenuBarDisplay()
            }
            .store(in: &cancellables)

        setupTimer()

        prepareStatusIcons()

        // Icon will be set by updateMenuBarDisplay() based on display mode

        // Request notification permission for banner alerts only if supported (built as .app)
        if notificationsSupported {
            Task { await refreshNotificationStatus(requestPermission: true) }
        }
        // Prime Accessibility status
        accessibilityTrusted = AXIsProcessTrusted()
        refreshAutomationPermissionStatus()
        startPermissionMonitor()
    }

    func requestAccessibilityPermission() {
        // Open System Settings to the Accessibility pane and begin polling status
        openAccessibilitySettings()
        accessibilityPollTimer?.invalidate()
        accessibilityPollAttempts = 0
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.accessibilityTrusted = AXIsProcessTrusted()
                self.accessibilityPollAttempts += 1
                if self.accessibilityTrusted || self.accessibilityPollAttempts >= 60 {
                    self.accessibilityPollTimer?.invalidate(); self.accessibilityPollTimer = nil
                }
            }
        }
        if let t = accessibilityPollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func openAccessibilitySettings() {
        let anchors = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for link in anchors {
            if let url = URL(string: link), NSWorkspace.shared.open(url) {
                break
            }
        }
    }

    func requestAutomationPermission() {
        let scriptSource = """
            tell application \"System Events\"
                return name of it
            end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else { return }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)

        refreshAutomationPermissionStatus()

        if automationPermissionStatus != .allowed {
            openAutomationSettings()
        }
    }

    private func refreshAutomationPermissionStatus() {
        guard systemEventsRunning else {
            automationPermissionStatus = .unknown
            return
        }

        let descriptor = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard let aePointer = descriptor.aeDesc else {
            automationPermissionStatus = .unknown
            return
        }

        let status = aePointer.withMemoryRebound(to: AEAddressDesc.self, capacity: 1) {
            AEDeterminePermissionToAutomateTarget($0, kCoreEventClass, kAEOpenApplication, false)
        }

        if status == noErr {
            automationPermissionStatus = .allowed
        } else {
            automationPermissionStatus = .denied
        }
    }

    private func openAutomationSettings() {
        let anchors = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for link in anchors {
            if let url = URL(string: link), NSWorkspace.shared.open(url) {
                break
            }
        }
    }

    private func startPermissionMonitor() {
        permissionMonitorTimer?.invalidate()
        let timer = Timer(timeInterval: 5.0, target: self, selector: #selector(handlePermissionMonitor(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        permissionMonitorTimer = timer
    }

    @objc private func handlePermissionMonitor(_ timer: Timer) {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
        }
        refreshAutomationPermissionStatus()
    }

    private func color(forBlinkName name: String) -> NSColor {
        switch name {
        case "systemRed": return .systemRed
        case "systemBlue": return .systemBlue
        case "systemYellow": return .systemYellow
        case "systemOrange": return .systemOrange
        case "systemGreen": return .systemGreen
        case "systemPurple": return .systemPurple
        default: return .systemGray
        }
    }

    private var systemEventsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty
    }

    func loadSettings() {
        if let displayModeRawValue = UserDefaults.standard.string(forKey: "displayMode"),
           let displayMode = DisplayMode(rawValue: displayModeRawValue) {
            self.displayMode = displayMode
        }

        if UserDefaults.standard.object(forKey: "autoRefreshEnabled") != nil {
            self.autoRefreshEnabled = UserDefaults.standard.bool(forKey: "autoRefreshEnabled")
        } else {
            self.autoRefreshEnabled = true
        }

        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        self.refreshInterval = interval > 0 ? interval : 5.0

        if UserDefaults.standard.object(forKey: "blinkingEnabled") != nil {
            self.blinkingEnabled = UserDefaults.standard.bool(forKey: "blinkingEnabled")
        } else {
            self.blinkingEnabled = true
        }

        // New toggles defaults
        if UserDefaults.standard.object(forKey: "soundOnIncrease") != nil {
            self.soundOnIncrease = UserDefaults.standard.bool(forKey: "soundOnIncrease")
        } else {
            self.soundOnIncrease = true
        }
        if UserDefaults.standard.object(forKey: "notificationOnIncrease") != nil {
            self.notificationOnIncrease = UserDefaults.standard.bool(forKey: "notificationOnIncrease")
        } else {
            self.notificationOnIncrease = true
        }
        if UserDefaults.standard.object(forKey: "popoverBannerOnIncrease") != nil {
            self.popoverBannerOnIncrease = UserDefaults.standard.bool(forKey: "popoverBannerOnIncrease")
        } else {
            self.popoverBannerOnIncrease = true
        }
        if UserDefaults.standard.object(forKey: "showSearchBar") != nil {
            self.showSearchBar = UserDefaults.standard.bool(forKey: "showSearchBar")
        } else {
            self.showSearchBar = true
        }

        if UserDefaults.standard.object(forKey: "menuBarSummaryEnabled") != nil {
            self.menuBarSummaryEnabled = UserDefaults.standard.bool(forKey: "menuBarSummaryEnabled")
        } else {
            self.menuBarSummaryEnabled = false
        }
        let savedSummaryLimit = UserDefaults.standard.integer(forKey: "menuBarSummaryLimit")
        self.menuBarSummaryLimit = savedSummaryLimit > 0 ? savedSummaryLimit : 2

        if let savedSound = UserDefaults.standard.string(forKey: "alarmSoundName"), !savedSound.isEmpty {
            self.alarmSoundName = savedSound
        } else {
            self.alarmSoundName = "Glass"
        }

        if let savedBlinkColor = UserDefaults.standard.string(forKey: "blinkColorName"), !savedBlinkColor.isEmpty {
            self.blinkColorName = savedBlinkColor
        } else {
            self.blinkColorName = "systemGray"
        }

        if let savedIcon = UserDefaults.standard.string(forKey: "notificationIcon"), !savedIcon.isEmpty {
            self.notificationIcon = savedIcon
        } else {
            self.notificationIcon = "📢"
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        refreshTask?.cancel()
        refreshTask = nil
        removeEventMonitors()
        timer?.invalidate()
        blinkingTimer?.invalidate()
        accessibilityPollTimer?.invalidate()
        permissionMonitorTimer?.invalidate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await refreshNotificationStatus() }
        refreshLoginItemStatus()
        // Refresh accessibility status when returning from System Settings
        accessibilityTrusted = AXIsProcessTrusted()
        if accessibilityTrusted {
            accessibilityPollTimer?.invalidate(); accessibilityPollTimer = nil
        }
        refreshAutomationPermissionStatus()
    }

    func setupTimer() {
        timer?.invalidate()
        timer = nil
        guard autoRefreshEnabled, !isSleeping, refreshTask == nil else { return }

        let newTimer = Timer(timeInterval: effectiveRefreshInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMenuBarDisplay() }
        }
        // Add to common modes so it continues while menus/popovers are active
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    @objc func workspaceWillSleep() {
        isSleeping = true
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        blinkingTimer?.invalidate()
        blinkingTimer = nil
        blinkContext = nil
        permissionMonitorTimer?.invalidate()
        accessibilityPollTimer?.invalidate()
    }

    @objc func workspaceDidWake() {
        isSleeping = false
        consecutiveScanFailures = 0
        startPermissionMonitor()
        if autoRefreshEnabled { updateMenuBarDisplay() }
    }

    func waitForRefresh() async {
        await refreshTask?.value
    }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        loginItemEnabled = status == .enabled || status == .requiresApproval
        loginItemNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemStatus()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusBarItem?.button, let popover {
            if popover.isShown {
                closePopover(sender)
            } else {
                // An empty rect follows the button's bounds as the status item resizes.
                popover.show(relativeTo: .zero, of: button, preferredEdge: .minY)
                installEventMonitors()
            }
        }
    }

    private func closePopover(_ sender: AnyObject?) {
        // Previews create the delegate without running application startup.
        if let popover, popover.isShown { popover.performClose(sender) }
        removeEventMonitors()
    }

    func dismissPopover() {
        closePopover(nil)
    }

    func showSettings() {
        // Settings must not be anchored to the menu item whose width it changes.
        closePopover(nil)
        if settingsWindowController == nil {
            let controller = NSHostingController(rootView: SettingsRootView().environmentObject(self))
            let window = NSWindow(contentViewController: controller)
            window.title = "NotiBar Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 520, height: 640))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func closeSettings() {
        settingsWindowController?.close()
    }

    private func installEventMonitors() {
        removeEventMonitors()
        // Global monitor catches clicks outside the app
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            DispatchQueue.main.async { [weak self] in self?.handleOutsideClick(event: event) }
        }
        // Local monitor catches clicks inside the app but outside the popover content
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            DispatchQueue.main.async { [weak self] in self?.handleOutsideClick(event: event) }
            return event
        }
    }

    private func removeEventMonitors() {
        if let m = globalEventMonitor { NSEvent.removeMonitor(m) }
        if let m = localEventMonitor { NSEvent.removeMonitor(m) }
        globalEventMonitor = nil
        localEventMonitor = nil
    }

    private func handleOutsideClick(event: NSEvent) {
        guard let popover, popover.isShown else { return }
        // While Settings sheet is open, ignore outside clicks to keep it open
        if isSettingsPresented { return }
        // If click is within popover or on the status item button, ignore
        if let popWindow = popover.contentViewController?.view.window {
            let loc = event.locationInWindow
            if event.window === popWindow, popWindow.contentView?.frame.contains(loc) == true { return }
            // Convert to screen and compare frames
            let screenPoint = event.locationInWindow
            if let eventWin = event.window {
                let screenLoc = eventWin.convertPoint(toScreen: screenPoint)
                if popWindow.frame.contains(screenLoc) { return }
                if let btn = statusBarItem?.button, let btnWin = btn.window {
                    let btnRect = btnWin.convertToScreen(btn.convert(btn.bounds, to: nil))
                    if btnRect.contains(screenLoc) { return }
                }
            }
        }
        closePopover(nil)
    }

    // NSPopoverDelegate
    func popoverDidClose(_ notification: Notification) {
        removeEventMonitors()
    }

    @objc func updateMenuBarDisplay() {
        guard statusBarItem != nil else { return }
        prepareStatusIcons()
        statusBarItem.menu = nil
        statusBarItem.button?.target = self
        statusBarItem.button?.action = #selector(togglePopover(_:))

        if displayMode == .popover {
            configureButtonForIconOnly()
            setPopoverIcon()
        } else {
            updateTitle(appsWithBadges: applicationsWithBadges)
        }

        // Timer ticks and settings changes share the scan already in progress.
        guard refreshTask == nil, !isSleeping else { return }
        timer?.invalidate()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            defer {
                self.isRefreshing = false
                self.refreshTask = nil
                self.setupTimer()
            }
            let applications: [Application]
            do {
                applications = try await self.fetchDockApplications()
            } catch {
                // A failed scan is not an empty Dock. Preserve the displayed
                // snapshot and comparison baseline until a scan succeeds.
                if !Task.isCancelled {
                    self.consecutiveScanFailures += 1
                    self.refreshError = (error as? DockScanError)?.userMessage
                        ?? "Couldn’t read Dock badges. Try refreshing again."
                    NSLog("Dock scan failed: %@", String(describing: error))
                }
                return
            }
            guard !Task.isCancelled, !self.isSleeping else { return }

            let appsWithBadges = self.applicationCatalog.resolve(applications).filter { $0.badgeCount > 0 }
            let newBadgeCounts = appsWithBadges.reduce(into: [String: Int]()) {
                $0[$1.id] = $1.badgeCount
            }
            let increasedApps = appsWithBadges.filter {
                self.hasBaseline && self.previousBadgeCounts[$0.id, default: 0] < $0.badgeCount
            }

            // Both presentations consume the same snapshot.
            if self.applicationsWithBadges != appsWithBadges {
                self.applicationsWithBadges = appsWithBadges
            }
            self.hasBaseline = true
            self.consecutiveScanFailures = 0
            self.lastSuccessfulRefresh = Date()
            self.refreshError = nil
            if !increasedApps.isEmpty {
                if self.soundOnIncrease { self.playAlertSound() }
                if self.notificationOnIncrease && self.notificationsSupported {
                    self.postIncreaseNotification(for: increasedApps)
                }
                self.pendingIconAlert = true
            } else if appsWithBadges.isEmpty {
                self.pendingIconAlert = false
                self.lastIncreaseSummary = nil
            }

            // Use the current mode, including changes made during the scan.
            if self.displayMode == .popover {
                if !increasedApps.isEmpty && self.popoverBannerOnIncrease {
                    self.showPopoverBanner(for: increasedApps, newBadgeCounts: newBadgeCounts)
                }
                self.setPopoverIcon()
            } else if !increasedApps.isEmpty && self.blinkingEnabled {
                self.startBlinking(appsWithBadges: appsWithBadges, newBadgeCounts: newBadgeCounts)
            } else {
                self.updateTitle(appsWithBadges: appsWithBadges)
            }
            self.previousBadgeCounts = newBadgeCounts
        }
    }

    // No separate direct-mode window; both modes use the same popover on click

    private func playAlertSound() {
        playSound(named: alarmSoundName)
    }

    func previewAlarm() {
        guard soundOnIncrease else { return }
        playSound(named: alarmSoundName)
    }

    private func playSound(named name: String) {
        // Try NSSound by name first
        if let s = NSSound(named: NSSound.Name(name)) {
            s.stop(); s.play(); return
        }
        // Try system sounds folder
        let fm = FileManager.default
        let candidates = [
            "/System/Library/Sounds/\(name).aiff",
            "/System/Library/Sounds/\(name).caf",
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            if let s = NSSound(contentsOfFile: path, byReference: true) {
                s.stop(); s.play(); return
            }
        }
        // Fallback
        NSSound.beep()
    }

    func showPopoverBanner(for increasedApps: [Application], newBadgeCounts: [String: Int]) {
        let top = increasedApps.prefix(3)
        let summary = top.map { app in
            let curr = newBadgeCounts[app.id] ?? app.badgeCount
            let prev = previousBadgeCounts[app.id, default: 0]
            let rawDelta = curr - prev
            if rawDelta > 0 {
                return "\(app.name)(+\(rawDelta))"
            } else if curr > 0 {
                // Fallback for first-run or transient reads that returned 0 earlier
                return "\(app.name)(\(curr))"
            } else {
                return app.name
            }
        }.joined(separator: ", ")
        let message = summary.isEmpty ? "Badge changes detected" : "\(summary)"
        lastIncreaseSummary = "\(message)"

        // Auto-dismiss after a delay if unchanged (10 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            if self.lastIncreaseSummary == "\(message)" {
                self.lastIncreaseSummary = nil
            }
        }
    }

    // removed temporary tint method (unused)

    // Badge presence determines the icon, independently of new-activity alerts.
    func setPopoverIcon() {
        prepareStatusIcons()
        guard let button = statusBarItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        let hasBadges = applicationsWithBadges.contains { $0.badgeCount > 0 }
        let image = hasBadges ? (iconAlert ?? iconNormal) : iconNormal
        button.image = image
        button.contentTintColor = nil
        button.toolTip = "Open NotiBar"
    }

    private func configureButtonForIconOnly() {
        prepareStatusIcons()
        statusBarItem.length = NSStatusItem.squareLength
        guard let button = statusBarItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = iconNormal ?? iconAlert
        button.contentTintColor = nil
        button.toolTip = "Open NotiBar"
    }

    private func configureButtonForText() {
        guard let button = statusBarItem.button else { return }
        button.image = nil
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = nil
        button.contentTintColor = nil
        button.attributedTitle = NSAttributedString(string: "")
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.alignment = .center
        button.cell?.wraps = false
        button.cell?.isScrollable = true
        button.cell?.lineBreakMode = .byClipping
    }

    private func adjustStatusItemLength(for title: String) {
        guard let button = statusBarItem.button else { return }
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let width = (title as NSString).size(withAttributes: [.font: font]).width + 18
        statusBarItem.length = max(width, NSStatusItem.squareLength)
    }


    private func prepareStatusIcons() {
        guard iconNormal == nil || iconAlert == nil else { return }
        let size = NSSize(width: 18, height: 18)
        if iconNormal == nil, let normal = NSImage(systemSymbolName: "bell", accessibilityDescription: "NotiBar") {
            normal.isTemplate = true
            normal.size = size
            iconNormal = normal
        }
        if iconAlert == nil, let alert = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "NotiBar: unread badges") {
            alert.isTemplate = true
            alert.size = size
            iconAlert = alert
        }
    }

    private func menuBarDisplay(for apps: [Application]) -> (title: String, tooltip: String?) {
        guard !apps.isEmpty else { return ("No Badges", nil) }
        let ordered = apps
        let full = fullTitle(for: ordered)
        if menuBarSummaryEnabled {
            let summary = summaryTitle(for: ordered)
            let tooltip = summary == full ? nil : full
            return (summary, tooltip)
        }
        return (full, nil)
    }

    private func summaryTitle(for apps: [Application]) -> String {
        guard !apps.isEmpty else { return "No Badges" }
        let limit = max(1, menuBarSummaryLimit)
        let displayed = Array(apps.prefix(limit))
        var parts = displayed.map { summaryFragment(for: $0) }
        let remaining = apps.count - displayed.count
        if remaining > 0 {
            parts.append("+\(remaining) more")
        }
        return parts.joined(separator: " | ")
    }

    private func summaryFragment(for app: Application) -> String {
        let maxNameLength = 12
        var name = app.name
        if name.count > maxNameLength {
            let index = name.index(name.startIndex, offsetBy: maxNameLength)
            name = String(name[..<index]) + "…"
        }
        return "\(name): \(app.badgeCount)"
    }

    private func fullTitle(for apps: [Application]) -> String {
        guard !apps.isEmpty else { return "No Badges" }
        return apps.map { "\($0.name): \($0.badgeCount)" }.joined(separator: " | ")
    }


    // Foreground apps must explicitly opt in to banner presentation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor [weak self] in
            completionHandler(self?.notificationOnIncrease == true ? [.banner, .list, .sound] : [])
        }
    }

    @discardableResult
    func refreshNotificationStatus(requestPermission: Bool = false) async -> Bool {
        guard notificationsSupported else { return false }
        let center = UNUserNotificationCenter.current()
        notificationError = nil
        var settings = await center.notificationSettings()
        if requestPermission && settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            } catch {
                notificationError = error.localizedDescription
            }
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationStatus = settings.alertSetting == .enabled ? "Allowed" : "Banners disabled"
            if settings.alertSetting != .enabled {
                notificationError = "Enable notification alerts for NotiBar in System Settings."
            }
        case .denied:
            notificationStatus = "Not allowed"
            notificationError = "Allow notifications for NotiBar in System Settings."
        case .notDetermined:
            notificationStatus = "Not requested"
        @unknown default:
            notificationStatus = "Unknown"
        }
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func sendTestNotification() {
        guard notificationOnIncrease else {
            notificationTestResult = "Turn on System notifications before sending a test."
            return
        }
        guard !isTestingNotification else { return }
        let generation = notificationGeneration
        isTestingNotification = true
        notificationTestResult = "Checking permission…"
        Task {
            defer { isTestingNotification = false }
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            guard await refreshNotificationStatus(requestPermission: true) else {
                notificationTestResult = "Not sent. Allow notifications in macOS Settings."
                return
            }
            guard notificationOnIncrease, generation == notificationGeneration else {
                notificationTestResult = "Cancelled: system notifications were turned off."
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "NotiBar test notification"
            content.body = "Notification check at \(Date().formatted(date: .omitted, time: .standard))."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
            )
            do {
                try await center.add(request)
                guard notificationOnIncrease, generation == notificationGeneration else {
                    center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    notificationTestResult = "Cancelled: system notifications were turned off."
                    return
                }
                notificationTestResult = "Accepted by macOS. Waiting for delivery…"
                try await Task.sleep(for: .seconds(4))
                let delivered = await center.deliveredNotifications()
                if delivered.contains(where: { $0.request.identifier == request.identifier }) {
                    notificationTestResult = "Delivered to Notification Center. If no banner appeared, check Focus and NotiBar’s macOS alert settings."
                } else {
                    notificationTestResult = "Accepted by macOS, but not found in Notification Center. It may have been dismissed or suppressed."
                }
            } catch {
                notificationError = error.localizedDescription
                notificationTestResult = "Notification check failed."
            }
        }
    }

    func postIncreaseNotification(for increasedApps: [Application]) {
        guard notificationOnIncrease else { return }
        let generation = notificationGeneration
        let center = UNUserNotificationCenter.current()
        let top = increasedApps.prefix(3)
        let summary = top.map { app in
            let prev = previousBadgeCounts[app.id, default: 0]
            let delta = max(0, app.badgeCount - prev)
            return "\(app.name)(+\(delta))"
        }.joined(separator: ", ")
        let content = UNMutableNotificationContent()
        content.title = "\(notificationIcon) Badge updates"
        content.body = summary.isEmpty ? "NotiBar notifications are working." : summary
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            center.delegate = self
            guard notificationOnIncrease, generation == notificationGeneration else { return }
            guard await refreshNotificationStatus(requestPermission: true) else { return }
            guard notificationOnIncrease, generation == notificationGeneration else { return }
            do {
                try await center.add(request)
                if !notificationOnIncrease || generation != notificationGeneration {
                    center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                }
            } catch {
                notificationError = "Couldn’t send notification: \(error.localizedDescription)"
            }
        }
    }

    func updateTitle(appsWithBadges: [Application]) {
        configureButtonForText()
        let orderedApps = appsWithBadges.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let display = menuBarDisplay(for: orderedApps)
        statusBarItem.button?.title = display.title
        statusBarItem.button?.attributedTitle = NSAttributedString(string: display.title)
        statusBarItem.button?.image = nil
        statusBarItem.button?.toolTip = display.tooltip
        adjustStatusItemLength(for: display.title)
    }

    func startBlinking(appsWithBadges: [Application], newBadgeCounts: [String: Int]) {
        timer?.invalidate()
        blinkingTimer?.invalidate()
        isBlinking = false
        blinkCounter = 0
        let blinkCount = 6 // 3 pulses
        configureButtonForText()
        let orderedApps = appsWithBadges.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let display = menuBarDisplay(for: orderedApps)
        statusBarItem.button?.title = display.title
        statusBarItem.button?.attributedTitle = NSAttributedString(string: display.title)
        statusBarItem.button?.toolTip = display.tooltip
        adjustStatusItemLength(for: display.title)

        pendingIconAlert = true
        previousBadgeCounts = newBadgeCounts
        blinkContext = BlinkContext(fullTitle: display.title, newBadgeCounts: newBadgeCounts, maxBlinkCount: blinkCount)
        blinkingTimer = Timer.scheduledTimer(timeInterval: 0.6, target: self, selector: #selector(handleBlinkTimer(_:)), userInfo: nil, repeats: true)
        if let blinkingTimer {
            RunLoop.main.add(blinkingTimer, forMode: .common)
        }
    }

    @objc private func handleBlinkTimer(_ timer: Timer) {
        guard let context = blinkContext else { return }

        if blinkCounter >= context.maxBlinkCount {
            timer.invalidate()
            blinkingTimer = nil
            blinkContext = nil
            statusBarItem.button?.title = context.fullTitle
            statusBarItem.button?.attributedTitle = NSAttributedString(string: context.fullTitle)
            previousBadgeCounts = context.newBadgeCounts
            setupTimer()
            return
        }

        isBlinking.toggle()
        // Only change color: inserting a symbol or resizing on each pulse moves
        // adjacent menu items and any popover anchored to this button.
        if let button = statusBarItem?.button {
            button.attributedTitle = NSAttributedString(
                string: context.fullTitle,
                attributes: [
                    .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: isBlinking ? color(forBlinkName: blinkColorName) : NSColor.labelColor
                ]
            )
        }

        blinkCounter += 1
    }
}

