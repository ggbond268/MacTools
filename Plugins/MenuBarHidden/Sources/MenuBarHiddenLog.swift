// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import Foundation
import OSLog

enum MenuBarHiddenLog {
    static let plugin = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MenuBarHiddenPlugin"
    )
}
