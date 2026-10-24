import Foundation
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable {
    case popover = "Popover"
    case direct = "Menu Bar"

    var id: String { self.rawValue }
}

enum AutomationPermissionStatus {
    case unknown
    case allowed
    case denied

    var displayText: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .allowed:
            return "Allowed"
        case .denied:
            return "Not Allowed"
        }
    }

    var statusColor: Color {
        switch self {
        case .allowed:
            return .green
        case .denied:
            return .red
        case .unknown:
            return .secondary
        }
    }
}

nonisolated struct Application: Identifiable, Equatable, Sendable {
    let name: String
    let badgeCount: Int
    var applicationURL: URL? = nil

    // Dock URLs remain stable when counts, names, or row order change.
    // Older/missing AXURL responses fall back to the name.
    var id: String {
        applicationURL?.standardizedFileURL.absoluteString ?? "name:\(name)"
    }
}

// Enumerate Dock items (running or pinned) and return their badge counts.
// This captures more than just running apps and allows showing any app with a badge > 0.
