import SwiftUI
import AppKit

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Version \(version)"
    }
    private var descriptionText: String {
        "NotiBar keeps an eye on your Dock badge counts and surfaces the apps with new activity right in the menu bar."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NotiBar")
                .font(.title2)
                .bold()
            Text(appVersion)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(descriptionText)
                .font(.body)
            Link("More details at https://notibar.app", destination: URL(string: "https://notibar.app")!)
                .font(.body.weight(.semibold))
            Spacer()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

