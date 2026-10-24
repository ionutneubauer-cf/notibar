import SwiftUI
import AppKit

@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()
    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 128
    }

    func icon(for url: URL) -> NSImage? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else { return nil }
        let key = url.standardizedFileURL as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }
}

struct ApplicationIconView: View {
    let applicationURL: URL?
    @State private var icon: NSImage?

    var body: some View {
        ZStack {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
        .task(id: applicationURL) {
            // Load outside body evaluation, and reuse icons across refreshes.
            icon = applicationURL.flatMap { ApplicationIconCache.shared.icon(for: $0) }
        }
    }
}
