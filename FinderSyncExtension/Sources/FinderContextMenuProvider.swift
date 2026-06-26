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
/// Actions split by capability: copy actions run inside the sandboxed extension
/// (the pasteboard needs no file access); file-creating / app-launching actions
/// are forwarded to the non-sandboxed host app via the `mactools://` URL scheme,
/// so this extension stays at minimal entitlements (sandbox only).
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
        // Read user configuration shared from the host app via the app group;
        // each action still resolves its own targets from the controller.
        let configuration = FinderMenuConfigStore.load()
        let menu = NSMenu(title: "MacTools")
        addCopyMenu(to: menu, configuration: configuration)
        if configuration.newFileEnabled {
            addNewFileMenu(to: menu)
        }
        if configuration.openInTerminal {
            addOpenInTerminalItem(to: menu)
        }
        return menu
    }

    private func addCopyMenu(to menu: NSMenu, configuration: FinderMenuConfiguration) {
        guard configuration.hasAnyCopyAction else { return }
        let parent = NSMenuItem(title: "复制路径", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        let submenu = NSMenu(title: "复制路径")
        if configuration.copyAbsolutePath {
            submenu.addItem(makeItem("复制绝对路径", #selector(copyAbsolutePaths(_:))))
        }
        if configuration.copyShellEscapedPath {
            submenu.addItem(makeItem("复制转义路径", #selector(copyShellEscapedPaths(_:))))
        }
        if configuration.copyFileName {
            submenu.addItem(makeItem("复制文件名", #selector(copyFileNames(_:))))
        }
        if configuration.copyFileURL {
            submenu.addItem(makeItem("复制 file:// 链接", #selector(copyFileURLs(_:))))
        }
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

    private func addOpenInTerminalItem(to menu: NSMenu) {
        let item = makeItem("在终端打开", #selector(openInTerminal(_:)))
        item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        menu.addItem(item)
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Copy actions (run in-extension; pasteboard needs no file access)

    @objc private func copyAbsolutePaths(_ sender: NSMenuItem) {
        let urls = effectiveTargets()
        guard !urls.isEmpty else { return }
        writeToPasteboard(urls.map(\.path).joined(separator: "\n"))
    }

    /// Shell-escaped paths, space-separated so the whole line can be pasted as
    /// terminal arguments.
    @objc private func copyShellEscapedPaths(_ sender: NSMenuItem) {
        let urls = effectiveTargets()
        guard !urls.isEmpty else { return }
        let text = urls.map { FinderContextMenuLogic.shellEscaped($0.path) }.joined(separator: " ")
        writeToPasteboard(text)
    }

    @objc private func copyFileNames(_ sender: NSMenuItem) {
        let urls = effectiveTargets()
        guard !urls.isEmpty else { return }
        writeToPasteboard(urls.map(\.lastPathComponent).joined(separator: "\n"))
    }

    @objc private func copyFileURLs(_ sender: NSMenuItem) {
        let urls = effectiveTargets()
        guard !urls.isEmpty else { return }
        writeToPasteboard(urls.map(\.absoluteString).joined(separator: "\n"))
    }

    // MARK: - Forwarded actions (host app performs them; extension stays sandboxed)

    @objc private func newTextFile(_ sender: NSMenuItem) { requestNewFile(ext: "txt") }
    @objc private func newMarkdownFile(_ sender: NSMenuItem) { requestNewFile(ext: "md") }
    @objc private func newJSONFile(_ sender: NSMenuItem) { requestNewFile(ext: "json") }

    private func requestNewFile(ext: String) {
        guard let directory = targetDirectory() else {
            logger.error("new file: no target directory available")
            return
        }
        forwardRequest(host: "newfile", queryItems: [
            URLQueryItem(name: "dir", value: directory.path),
            URLQueryItem(name: "ext", value: ext)
        ])
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let directory = targetDirectory() else {
            logger.error("open in terminal: no target directory available")
            return
        }
        forwardRequest(host: "openterminal", queryItems: [
            URLQueryItem(name: "dir", value: directory.path)
        ])
    }

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

    /// Directory new-file / open-in-terminal apply to: the selected folder, the
    /// selected file's parent, or the current directory.
    private func targetDirectory() -> URL? {
        let controller = FIFinderSyncController.default()
        if let first = controller.selectedItemURLs()?.first {
            return first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        }
        return controller.targetedURL()
    }

    // MARK: - Host app forwarding

    /// Forward an action to the non-sandboxed host app through the `mactools://`
    /// URL scheme. The sandboxed extension cannot create files or launch apps in
    /// arbitrary locations, so the host app performs them — keeping this extension
    /// at minimal entitlements (sandbox only, no file-access exception).
    private func forwardRequest(host: String, queryItems: [URLQueryItem]) {
        var components = URLComponents()
        components.scheme = "mactools"
        components.host = host
        components.queryItems = queryItems
        guard let url = components.url else {
            logger.error("failed to build \(host) request URL")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Pasteboard

    private func writeToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
