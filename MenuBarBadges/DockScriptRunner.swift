import Foundation
import AppKit

enum DockScanError: Error {
    case scriptCreationFailed
    case executionFailed(code: Int?, message: String)
    case invalidResponse

    var userMessage: String {
        switch self {
        case .executionFailed(let code, _) where code == -1743:
            return "Allow NotiBar to control System Events in Privacy & Security → Automation."
        case .scriptCreationFailed, .executionFailed, .invalidResponse:
            return "Couldn’t read Dock badges. Try refreshing again."
        }
    }
}

actor DockScriptRunner {
    func fetchApplications() throws -> [Application] {
        return try autoreleasepool {
            let scriptSource = """
                tell application id \"com.apple.systemevents\"
                tell process \"Dock\"
                    tell list 1
                        set results to {}
                        set cnt to count of UI elements
                        repeat with i from 1 to cnt
                            try
                                set el to UI element i
                                set nm to ""
                                try
                                    set nm to name of el as string
                                end try
                                if nm is not "" then
                                    set badgeVal to 0
                                    try
                                        set badgeVal to value of attribute \"AXStatusLabel\" of el as integer
                                    end try
                                    set appURL to ""
                                    try
                                        set appURL to value of attribute \"AXURL\" of el as text
                                    end try
                                    set end of results to (nm & "|" & (badgeVal as string) & tab & appURL)
                                end if
                            end try
                        end repeat
                        set AppleScript's text item delimiters to "\n"
                        return results as text
                    end tell
                end tell
            end tell
        """

            guard let script = NSAppleScript(source: scriptSource) else {
                throw DockScanError.scriptCreationFailed
            }
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                throw DockScanError.executionFailed(
                    code: errorInfo[NSAppleScript.errorNumber] as? Int,
                    message: errorInfo[NSAppleScript.errorBriefMessage] as? String ?? "Unknown AppleScript error"
                )
            }
            guard let output = descriptor.stringValue else {
                throw DockScanError.invalidResponse
            }
            return try Self.parseApplications(output)
        }
    }

    nonisolated static func parseApplications(_ output: String) throws -> [Application] {
        var results: [Application] = []
        var seenIDs: Set<String> = []
        for record in output.split(separator: "\n") {
            let fields = record.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let line = fields[0]
            // Split at the final delimiter so app names may contain "|".
            guard let separator = line.lastIndex(of: "|") else {
                throw DockScanError.invalidResponse
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let count = Int(value), count >= 0 else {
                throw DockScanError.invalidResponse
            }
            let url: URL?
            if fields.count == 2, !fields[1].isEmpty {
                guard let parsedURL = URL(string: String(fields[1])), parsedURL.isFileURL else {
                    throw DockScanError.invalidResponse
                }
                url = parsedURL.standardizedFileURL
            } else {
                url = nil
            }
            let app = Application(name: name, badgeCount: count, applicationURL: url)
            // Duplicate Dock entries must not create duplicate SwiftUI row IDs.
            if seenIDs.insert(app.id).inserted {
                results.append(app)
            } else if let index = results.firstIndex(where: { $0.id == app.id }),
                      count > results[index].badgeCount {
                results[index] = app
            }
        }
        return results
    }
}

private let dockScriptRunner = DockScriptRunner()

func getDockApplications() async throws -> [Application] {
    try await dockScriptRunner.fetchApplications()
}



