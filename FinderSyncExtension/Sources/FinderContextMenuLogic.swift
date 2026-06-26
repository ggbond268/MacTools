import Foundation

/// Pure, headless-testable helpers for the Finder context-menu extension.
///
/// Kept free of AppKit / FinderSync so the path math can be unit-tested without
/// loading the extension or touching the real file system.
enum FinderContextMenuLogic {
    /// Compute `target` relative to the directory `base` (e.g. `"sub/file.txt"`,
    /// `"../sibling/file.txt"`). Falls back to `target`'s absolute path when the
    /// two share only the volume root, where a relative path would be a long,
    /// useless chain of `..`.
    static func relativePath(of target: URL, to base: URL) -> String {
        let baseComps = base.standardizedFileURL.pathComponents
        let targetComps = target.standardizedFileURL.pathComponents

        var common = 0
        while common < baseComps.count,
              common < targetComps.count,
              baseComps[common] == targetComps[common] {
            common += 1
        }

        // `common` always includes the leading "/". Anything that only shares
        // the root is on an unrelated subtree — prefer the absolute path.
        guard common > 1 else { return target.path }

        let ups = max(0, baseComps.count - common)
        let downs = Array(targetComps.dropFirst(common))
        let parts = Array(repeating: "..", count: ups) + downs
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
