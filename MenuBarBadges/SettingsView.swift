import SwiftUI
import AppKit

@available(macOS 12.0, *)
struct SettingsRootView: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        SettingsView(
            displayMode: $appDelegate.displayMode,
            autoRefreshEnabled: $appDelegate.autoRefreshEnabled,
            refreshInterval: $appDelegate.refreshInterval,
            blinkingEnabled: $appDelegate.blinkingEnabled
        )
    }
}

private struct DisplayModeControl: View {
    @Binding var selection: DisplayMode

    var body: some View {
        HStack {
            Text("Display Mode")
            Spacer()
            ForEach(DisplayMode.allCases) { mode in
                Button {
                    // Commit after the native control finishes its view update.
                    Task { @MainActor in
                        if selection != mode { selection = mode }
                    }
                } label: {
                    Text(mode.rawValue)
                        .frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                .tint(selection == mode ? Color.accentColor : Color.secondary)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
    }
}

struct SettingsView: View {
    private let soundNames: [String] = [
        "Glass", "Submarine", "Basso", "Bottle", "Frog", "Funk",
        "Hero", "Ping", "Pop", "Sosumi", "Tink"
    ]
    @Binding var displayMode: DisplayMode
    @Binding var autoRefreshEnabled: Bool
    @Binding var refreshInterval: Double
    @Binding var blinkingEnabled: Bool
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.title2.weight(.bold))
                    Text("Make NotiBar work your way.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(20)
            Divider()
            Form {
                Section {
                    DisplayModeControl(selection: $displayMode)

                    GroupBox("Startup") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Launch at Login", isOn: Binding(
                                get: { appDelegate.loginItemEnabled },
                                set: { value in
                                    Task { @MainActor in appDelegate.setLaunchAtLogin(value) }
                                }
                            ))
                            if appDelegate.loginItemNeedsApproval {
                                Button("Approve in Login Items…") { appDelegate.openLoginItemSettings() }
                            }
                            if let error = appDelegate.loginItemError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }

                    GroupBox("Refresh") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Auto Refresh", isOn: $autoRefreshEnabled)

                            Stepper(value: $refreshInterval, in: 1...60, step: 1) {
                                HStack {
                                    Text("Refresh interval")
                                    Spacer()
                                    Text("\(Int(refreshInterval)) sec")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!autoRefreshEnabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }

                    GroupBox("Search") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Show search", isOn: $appDelegate.showSearchBar)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }

                    GroupBox("Notifications") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("System notifications", isOn: $appDelegate.notificationOnIncrease)
                            Picker("Notification title emoji", selection: $appDelegate.notificationIcon) {
                                ForEach(["📢", "🔔", "🛎️", "✉️", "📬"], id: \.self) { icon in
                                    Text(icon).tag(icon)
                                }
                            }
                            .disabled(!appDelegate.notificationOnIncrease)
                            Toggle("Play sound", isOn: $appDelegate.soundOnIncrease)

                            HStack {
                                Picker("Sound", selection: $appDelegate.alarmSoundName) {
                                    ForEach(soundNames, id: \.self) { name in
                                        Text(name).tag(name)
                                    }
                                }
                                .disabled(!appDelegate.soundOnIncrease)

                                Button("Play") { appDelegate.previewAlarm() }
                                .disabled(!appDelegate.soundOnIncrease)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }

                    GroupBox("Support") {
                        VStack(alignment: .leading, spacing: 12) {
                            DisclosureGroup("Permissions") {
                                HStack(spacing: 10) {
                                    Text("Notifications")
                                    Spacer(minLength: 8)
                                    Text(appDelegate.notificationStatus)
                                        .foregroundColor(appDelegate.notificationStatus == "Allowed" ? .green :
                                            (appDelegate.notificationStatus == "Not allowed" || appDelegate.notificationStatus == "Banners disabled" ? .red : .secondary))
                                        .font(.subheadline)
                                    Button("Manage…") { appDelegate.openNotificationSettings() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                                HStack(spacing: 10) {
                                    Text("Accessibility")
                                    Spacer(minLength: 8)
                                    Text(appDelegate.accessibilityTrusted ? "Allowed" : "Not Allowed")
                                        .foregroundColor(appDelegate.accessibilityTrusted ? .green : .red)
                                        .font(.subheadline)
                                    Button("Manage…") {
                                        appDelegate.requestAccessibilityPermission()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                HStack(spacing: 10) {
                                    Text("Automation")
                                    Spacer(minLength: 8)
                                    Text(appDelegate.automationPermissionStatus.displayText)
                                        .foregroundColor(appDelegate.automationPermissionStatus.statusColor)
                                        .font(.subheadline)
                                    Button("Manage…") {
                                        appDelegate.requestAutomationPermission()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            DisclosureGroup("Notification troubleshooting") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Button("Send Test Notification") { appDelegate.sendTestNotification() }
                                        .disabled(appDelegate.isTestingNotification || !appDelegate.notificationOnIncrease)
                                    if let result = appDelegate.notificationTestResult {
                                        Text(result).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let error = appDelegate.notificationError {
                                        Text(error).font(.caption).foregroundStyle(.red)
                                    }
                                    Text("Focus and macOS notification settings can silence banners.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                } header: {
                    Text("General")
                } footer: {
                    Text("Applies to both display modes.")
                }

                Section {
                    Toggle("Show activity banner", isOn: $appDelegate.popoverBannerOnIncrease)
                } header: {
                    Text("Popover mode")
                } footer: {
                    Text("Applies when Display Mode is set to Popover.")
                }

                Section {
                    Toggle("Pulse on new activity", isOn: $blinkingEnabled)

                    Toggle("Compact summary", isOn: $appDelegate.menuBarSummaryEnabled)
                    Stepper(value: $appDelegate.menuBarSummaryLimit, in: 1...5) {
                        HStack {
                            Text("Visible apps")
                            Spacer()
                            Text("\(appDelegate.menuBarSummaryLimit)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!appDelegate.menuBarSummaryEnabled)
                    Picker("Pulse color", selection: $appDelegate.blinkColorName) {
                        ForEach(["systemGray", "systemRed", "systemBlue", "systemYellow", "systemOrange", "systemGreen", "systemPurple"], id: \.self) { name in
                            let label = name.replacingOccurrences(of: "system", with: "System ")
                            Text(label)
                                .tag(name)
                        }
                    }
                    .disabled(!blinkingEnabled)
                } header: {
                    Text("Menu Bar mode")
                } footer: {
                    Text("Applies when Display Mode is set to Menu Bar.")
                }
            }
            .formStyle(.grouped)
            .task {
                appDelegate.refreshLoginItemStatus()
                await appDelegate.refreshNotificationStatus()
            }

            Divider()
            HStack {
                Text("Changes are saved automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    appDelegate.closeSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
    }
}


#Preview("Settings") {
    SettingsRootView().environmentObject(AppDelegate())
}
