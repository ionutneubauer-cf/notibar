import SwiftUI
import AppKit

@available(macOS 12.0, *)
struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var searchText = ""
    @State private var showingHelp = false

    private var filteredApplications: [Application] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return appDelegate.applicationsWithBadges.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NotiBarHeader(autoRefreshEnabled: appDelegate.autoRefreshEnabled)
                .padding(20)

            if appDelegate.refreshError != nil || !appDelegate.accessibilityTrusted
                || appDelegate.automationPermissionStatus == .denied {
                RefreshStatusView(
                    isRefreshing: appDelegate.isRefreshing,
                    lastSuccess: appDelegate.lastSuccessfulRefresh,
                    errorMessage: appDelegate.refreshError,
                    accessibilityTrusted: appDelegate.accessibilityTrusted,
                    automationStatus: appDelegate.automationPermissionStatus,
                    refresh: { appDelegate.updateMenuBarDisplay() },
                    openSettings: { appDelegate.showSettings() }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if appDelegate.displayMode == .popover, let banner = appDelegate.lastIncreaseSummary {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(banner)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        appDelegate.lastIncreaseSummary = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss notification summary")
                    .help("Dismiss summary")
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if appDelegate.showSearchBar {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search apps", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if filteredApplications.isEmpty {
                BadgeEmptyState(
                    isSearching: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    accessibilityTrusted: appDelegate.accessibilityTrusted,
                    hasScanFailed: appDelegate.refreshError != nil,
                    isRefreshing: appDelegate.isRefreshing
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredApplications) { app in
                            BadgeApplicationRow(name: app.name, count: app.badgeCount, applicationURL: app.applicationURL)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }

            Divider()
            HStack(spacing: 12) {
                Button {
                    appDelegate.showSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Spacer()
                Button {
                    appDelegate.updateMenuBarDisplay()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(appDelegate.isRefreshing)
                .accessibilityLabel("Refresh badges")
                .help("Refresh badges")
                Button {
                    showingHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Help")
                .help("Help")
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 380, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
        .task {
            appDelegate.updateMenuBarDisplay()
        }
    }
}

struct NotiBarHeader: View {
    let autoRefreshEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("NotiBar")
                    .font(.title2.weight(.bold))
                Text("Your Dock notifications at a glance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(autoRefreshEnabled ? "Auto" : "Paused",
                  systemImage: autoRefreshEnabled ? "arrow.clockwise" : "pause.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .help(autoRefreshEnabled ? "Automatic refresh enabled" : "Automatic refresh paused")
        }
    }
}

struct BadgeApplicationRow: View {
    let name: String
    let count: Int
    var applicationURL: URL? = nil

    var body: some View {
        HStack(spacing: 12) {
            ApplicationIconView(applicationURL: applicationURL)
            Text(name)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(count, format: .number)
                .font(.callout.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

private struct BadgeEmptyState: View {
    let isSearching: Bool
    let accessibilityTrusted: Bool
    let hasScanFailed: Bool
    let isRefreshing: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isSearching ? "magnifyingglass" : (accessibilityTrusted ? "bell" : "lock.shield"))
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(isSearching ? "No matching apps" : (isRefreshing ? "Checking your Dock" : (hasScanFailed ? "Badges unavailable" : (accessibilityTrusted ? "No badges to show" : "Connect your Dock"))))
                .font(.headline)
            Text(isSearching ? "Try another app name." : (hasScanFailed
                 ? "Check the status above, then try refreshing."
                 : (accessibilityTrusted ? "Apps with Dock badges will appear here."
                 : "Open Settings to grant Accessibility access.")))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}


#Preview("Popover") {
    ContentView()
        .environmentObject(AppDelegate())
}

#Preview("Badge rows") {
    VStack(spacing: 8) {
        NotiBarHeader(autoRefreshEnabled: true)
            .padding(.bottom, 12)
        BadgeApplicationRow(
            name: "Finder",
            count: 12,
            applicationURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        )
        BadgeApplicationRow(name: "Mail", count: 128)
        BadgeApplicationRow(name: "An app with a longer display name", count: 3)
    }
    .padding(20)
    .frame(width: 380)
    .background(Color(nsColor: .windowBackgroundColor))
}
