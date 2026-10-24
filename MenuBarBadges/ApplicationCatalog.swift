import AppKit
import Foundation

@MainActor
final class ApplicationCatalog {
    private var resolvedURLs: [String: URL] = [:]

    func resolve(_ applications: [Application]) -> [Application] {
        let running = NSWorkspace.shared.runningApplications
        return applications.map { application in
            guard application.applicationURL == nil else { return application }
            let name = application.name
            var url = resolvedURLs[name]
            if url == nil {
                let matches = Set(running.filter { $0.localizedName == name }.compactMap(\.bundleURL))
                if matches.count == 1 {
                    url = matches.first
                } else if matches.isEmpty {
                    // Pinned, non-running apps can still have Dock badges.
                    let directories = [
                        URL(fileURLWithPath: "/Applications", isDirectory: true),
                        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                        URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
                    ]
                    // Treat the Dock label as a filename, never a relative path.
                    if !name.contains("/") && name != "." && name != ".." {
                        let installed = directories.map {
                            $0.appendingPathComponent(name).appendingPathExtension("app")
                        }.filter { FileManager.default.fileExists(atPath: $0.path) }
                        if installed.count == 1 { url = installed.first }
                    }
                }
                if let url { resolvedURLs[name] = url.standardizedFileURL }
            }
            var resolved = application
            resolved.applicationURL = url
            return resolved
        }
    }
}
