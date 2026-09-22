import CoreGraphics
import Foundation

struct WindowSwitcherListingPolicy: Equatable, Sendable {
    var includesMinimizedWindows = true
    var includesOtherDesktopWindows = true
    var includesFullscreenSpaceWindows = true

    static let `default` = WindowSwitcherListingPolicy()

    func admits(_ entry: WindowSwitcherAppEntry) -> Bool {
        if !includesMinimizedWindows, entry.isMinimized { return false }
        if !includesOtherDesktopWindows, entry.isOnOtherDesktop { return false }
        if !includesFullscreenSpaceWindows, entry.isOnFullscreenSpace { return false }
        return true
    }
}

enum WindowSwitcherListing {
    static func apply(_ entries: [WindowSwitcherAppEntry], policy: WindowSwitcherListingPolicy) -> [WindowSwitcherAppEntry] {
        entries.filter(policy.admits)
    }

    static func preferringUniqueWindowNumbers(_ entries: [WindowSwitcherAppEntry]) -> [WindowSwitcherAppEntry] {
        var claimed = Set<CGWindowID>()
        return entries.filter { entry in
            guard let number = entry.windowNumber else { return true }
            return claimed.insert(number).inserted
        }
    }
}
