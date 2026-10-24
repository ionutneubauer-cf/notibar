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

    @Environment(\.dismiss) private var dismiss
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
                Section(header: Text("General Settings")) {
                    DisplayModeControl(selection: $displayMode)
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

                    // Place alarm before auto refresh as requested
                    Toggle("Alarm", isOn: $appDelegate.soundOnIncrease)
                        .padding(.top, 8)

                    // Alarm sound selector with live preview
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

                    Toggle("Auto Refresh", isOn: $autoRefreshEnabled)
                        .padding(.top, 8)

                    // Stepper with label immediately adjacent (no extra gap)
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

                Section(header: Text("Popover Settings")) {
                    Toggle("System Notification", isOn: $appDelegate.notificationOnIncrease)
                    Toggle("In-Popover Red Banner", isOn: $appDelegate.popoverBannerOnIncrease)
                    Toggle("Show Search Bar", isOn: $appDelegate.showSearchBar)
                }

                Section(header: Text("Menu Bar Settings")) {
                    Toggle("System Notification", isOn: $appDelegate.notificationOnIncrease)
                    Toggle("Blink on New Notification", isOn: $blinkingEnabled)
                
                    Toggle("Compact Summary", isOn: $appDelegate.menuBarSummaryEnabled)
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
                    Picker("Blink Color", selection: $appDelegate.blinkColorName) {
                        ForEach(["systemGray", "systemRed", "systemBlue", "systemYellow", "systemOrange", "systemGreen", "systemPurple"], id: \.self) { name in
                            let label = name.replacingOccurrences(of: "system", with: "System ")
                            Text(label)
                                .tag(name)
                        }
                    }
                    Picker("Notification Icon", selection: $appDelegate.notificationIcon) {
                        ForEach(["📢", "🔔", "🛎️", "✉️", "📬"], id: \.self) { icon in
                            Text(icon).tag(icon)
                        }
                    }
                }

                Section(header: Text("Permissions")) {
                    HStack(spacing: 10) {
                        Text("Accessibility")
                        Spacer(minLength: 8)
                        Text(appDelegate.accessibilityTrusted ? "Allowed" : "Not Allowed")
                            .foregroundColor(appDelegate.accessibilityTrusted ? .green : .red)
                            .font(.subheadline)
                        Button("Grant Accessibility…") {
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
                        Button("Grant Automation…") {
                            appDelegate.requestAutomationPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .formStyle(.grouped)
            .task { appDelegate.refreshLoginItemStatus() }

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
