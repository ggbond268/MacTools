import AppKit
import FinderSync
import Foundation
import os

/// Finder Sync principal class — injects MacTools actions into Finder's
/// right-click (contextual) menu.
///
/// This is a **system-loaded app extension**, deliberately separate from
/// MacTools' in-process plugin host: Finder instantiates this class and calls
/// `menu(for:)` whenever the user right-clicks inside a monitored directory, and
/// the returned `NSMenu` items are merged into the contextual menu. Because it
/// is a passive, declarative extension point (Finder asks us for a menu; we
/// never intercept mouse events), it is unaffected by the macOS 27 menu-bar
/// rehosting that broke the status-item right-click.
///
/// MVP scope: copy paths + create new files. Both run entirely inside the
/// sandboxed extension — no app group, no container round-trip.
///
/// Action identity note: macOS strips `representedObject` from the menu items
/// handed back through FinderSync, so each action is a distinct `@objc`
/// selector that re-reads its targets from `FIFinderSyncController` at click
/// time, rather than carrying state on the menu item.
///
/// Concurrency note: this target builds with `SWIFT_STRICT_CONCURRENCY = minimal`.
/// FinderSync's `menu(for:)` is nonisolated yet returns a main-actor `NSMenu`,
/// which is fundamentally at odds with Swift 6 complete checking. Every
/// FinderSync callback runs on Finder's main thread, so there is no real
/// concurrency to guard against here.
final class FinderContextMenuProvider: FIFinderSync {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ggbond.mactools.findersync",
        category: "FinderContextMenu"
    )

    override init() {
        super.init()
        // Monitor the whole file system so the menu is available wherever the
        // user right-clicks. FinderSync grants the sandboxed extension implicit
        // access to the URLs Finder hands back for monitored directories.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        logger.info("FinderContextMenuProvider initialized")
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Same MacTools actions regardless of where the click landed; each
        // action resolves its own targets from the controller at click time.
        let menu = NSMenu(title: "MacTools")
        addCopyMenu(to: menu)
        addNewFileMenu(to: menu)
        return menu
    }

    private func addCopyMenu(to menu: NSMenu) {
        let parent = NSMenuItem(title: "复制路径", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        let submenu = NSMenu(title: "复制路径")
        submenu.addItem(makeItem("复制绝对路径", #selector(copyAbsolutePaths(_:))))
        submenu.addItem(makeItem("复制相对路径", #selector(copyRelativePaths(_:))))
        submenu.addItem(makeItem("复制文件名", #selector(copyFileNames(_:))))
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addNewFileMenu(to menu: NSMenu) {
        let parent = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        let submenu = NSMenu(title: "新建文件")
        submenu.addItem(makeItem("文本文件 (.txt)", #selector(newTextFile(_:))))
        submenu.addItem(makeItem("Markdown (.md)", #selector(newMarkdownFile(_:))))
        submenu.addItem(makeItem("JSON (.json)", #selector(newJSONFile(_:))))
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Copy actions

    @objc private func copyAbsolutePaths(_ sender: NSMenuItem) {
        let urls = effectiveTargets()
        guard !urls.isEmpty else { return }
        writeToPasteboard(urls.map(\.path).joined(separator: "\n"))
    }

    @objc private func copyRelativePaths(_ sender: NSMenuItem) {
        let urls = effectiveTargets()
        guard !urls.isEmpty else { return }
        let base = FIFinderSyncController.default().targetedURL()
        let text = urls.map { url in
            base.map { FinderContextMenuLogic.relativePath(of: url, to: $0) } ?? url.path
        }.joined(separator: "\n")
        writeToPasteboard(text)
    }

    @objc private func copyFileNames(_ sender: NSMenuItem) {
        let urls = effectiveTargets()
        guard !urls.isEmpty else { return }
        writeToPasteboard(urls.map(\.lastPathComponent).joined(separator: "\n"))
    }

    // MARK: - New file actions

    @objc private func newTextFile(_ sender: NSMenuItem) { createNewFile(ext: "txt") }
    @objc private func newMarkdownFile(_ sender: NSMenuItem) { createNewFile(ext: "md") }
    @objc private func newJSONFile(_ sender: NSMenuItem) { createNewFile(ext: "json") }

    // MARK: - Targets

    /// URLs the copy actions apply to: the selected items, or the current
    /// directory when nothing is selected (blank-area right-click).
    private func effectiveTargets() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        if let targeted = controller.targetedURL() {
            return [targeted]
        }
        return []
    }

    /// Directory a new file should be created in: the selected folder, the
    /// selected file's parent, or the current directory.
    private func newFileDirectory() -> URL? {
        let controller = FIFinderSyncController.default()
        if let first = controller.selectedItemURLs()?.first {
            return first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        }
        return controller.targetedURL()
    }

    // MARK: - File creation

    private func createNewFile(ext: String) {
        guard let directory = newFileDirectory() else {
            logger.error("new file: no target directory available")
            return
        }
        let fileURL = FinderContextMenuLogic.nextAvailableURL(
            in: directory, baseName: "未命名", ext: ext
        )
        let fileManager = FileManager.default

        // FinderSync has implicit access to URLs Finder hands back, so a direct
        // create usually succeeds; fall back to explicit security-scoped access.
        if fileManager.createFile(atPath: fileURL.path, contents: Data(), attributes: nil) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }

        let didStart = directory.startAccessingSecurityScopedResource()
        defer { if didStart { directory.stopAccessingSecurityScopedResource() } }
        if fileManager.createFile(atPath: fileURL.path, contents: Data(), attributes: nil) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            logger.error("new file: failed to create at \(fileURL.path, privacy: .public)")
        }
    }

    // MARK: - Pasteboard

    private func writeToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
