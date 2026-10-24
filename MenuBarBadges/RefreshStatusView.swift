import SwiftUI

struct RefreshStatusView: View {
    let isRefreshing: Bool
    let lastSuccess: Date?
    let errorMessage: String?
    let accessibilityTrusted: Bool
    let automationStatus: AutomationPermissionStatus
    let refresh: () -> Void
    let openSettings: () -> Void

    private var permissionNeeded: Bool {
        !accessibilityTrusted || automationStatus == .denied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…")
                } else if permissionNeeded {
                    Image(systemName: "lock.shield")
                    Text(!accessibilityTrusted ? "Accessibility access needed" : "Automation access needed")
                } else if let errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage)
                } else if let lastSuccess {
                    Image(systemName: "checkmark.circle")
                    Text("Updated \(lastSuccess, format: .dateTime.hour().minute().second())")
                } else {
                    Image(systemName: "clock")
                    Text("Waiting for the first refresh")
                }
                Spacer(minLength: 4)
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh badges")
                .help("Refresh badges")
            }
            if errorMessage != nil || permissionNeeded {
                if let lastSuccess {
                    Text("Showing saved badges from \(lastSuccess, format: .dateTime.hour().minute().second()).")
                        .foregroundStyle(.secondary)
                }
                if permissionNeeded {
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.borderless)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
