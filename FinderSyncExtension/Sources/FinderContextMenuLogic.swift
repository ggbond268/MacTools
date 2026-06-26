import Foundation

/// Pure, headless-testable helpers for the Finder context-menu extension.
///
/// Kept free of AppKit / FinderSync so the logic can be unit-tested without
/// loading the extension. (This file is also compiled directly into the test
/// bundle — see the test target sources — because an app-extension is not an
/// importable framework.)
enum FinderContextMenuLogic {
    /// Shell-escape a path so it can be pasted straight into a terminal: wrap the
    /// whole path in single quotes and rewrite any embedded single quote as the
    /// canonical `'\''` sequence. This is safe for spaces and every shell
    /// metacharacter, unlike a raw absolute path.
    static func shellEscaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
