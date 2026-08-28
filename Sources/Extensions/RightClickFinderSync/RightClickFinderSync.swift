import AppKit
import FinderSync
import Foundation
import OSLog

final class RightClickFinderSync: FIFinderSync {
    private enum ActionID {
        static let newFolder = "new-folder"
        static let newFile = "new-file"
        static let openInTerminal = "open-terminal"
        static let openWith = "open-with"
        static let copyFileName = "copy-file-name"
        static let copyAbsolutePath = "copy-absolute-path"
        static let copyRelativePath = "copy-relative-path"
        static let copyShellEscapedPath = "copy-shell-escaped-path"
        static let copyFileURL = "copy-file-url"
    }

    private final class MenuActionContext: NSObject {
        let actionID: String
        let directory: URL?
        let fileExtension: String?
        let appPath: String?
        let copyTargets: RightClickCopyTargets?

        init(
            actionID: String,
            directory: URL? = nil,
            fileExtension: String? = nil,
            appPath: String? = nil,
            copyTargets: RightClickCopyTargets? = nil
        ) {
            self.actionID = actionID
            self.directory = directory
            self.fileExtension = fileExtension
            self.appPath = appPath
            self.copyTargets = copyTargets
        }
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools.right-click.finder-sync",
        category: "RightClickFinderSync"
    )
    private var titleToActionContext: [String: MenuActionContext] = [:]
    private var lastSelectedURLs: [URL] = []
    private var lastTargetedURL: URL?
    private let hostURLScheme = Bundle.main.object(forInfoDictionaryKey: "MTRightClickHostURLScheme") as? String ?? "mactools"
    private let configuredToolbarItemName = Bundle.main.object(
        forInfoDictionaryKey: "MTRightClickToolbarItemName"
    ) as? String ?? "MacTools"

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = Self.monitoredDirectories()
        let monitoredPaths = FIFinderSyncController.default().directoryURLs.map(\.path).joined(separator: ", ")
        logger.info("RightClick Finder Sync loaded. Monitoring: \(monitoredPaths, privacy: .public)")
    }

    override var toolbarItemName: String {
        configuredToolbarItemName
    }

    override var toolbarItemToolTip: String {
        if hostURLScheme == "mactools-nightly",
           let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return displayName
        }

        let configuration = RightClickConfigurationStore.load()
        return RightClickLocalization.string(
            "finder.toolbarToolTip",
            defaultValue: "MacTools 右键工具",
            preferredLanguages: configuration.preferredLanguages
        )
    }

    override var toolbarItemImage: NSImage {
        let image = NSImage(
            systemSymbolName: "contextualmenu.and.cursorarrow",
            accessibilityDescription: configuredToolbarItemName
        )
            ?? NSImage()
        image.isTemplate = true
        return image
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        let selectedURLs = controller.selectedItemURLs() ?? []
        let targetedURL = controller.targetedURL()

        lastSelectedURLs = selectedURLs
        lastTargetedURL = targetedURL
        titleToActionContext.removeAll()

        let configuration = RightClickConfigurationStore.load()
        guard configuration.menuEnabled else {
            return nil
        }

        let menu = NSMenu(title: configuredToolbarItemName)

        switch menuKind {
        case .contextualMenuForContainer:
            if let copyTargets = RightClickCopyTargetResolver.currentDirectory(targetedURL: targetedURL),
               let directory = copyTargets.urls.first {
                addDirectoryItems(to: menu, directory: directory, configuration: configuration)
                addPathCopyItems(to: menu, configuration: configuration, targets: copyTargets)
                addOpenWithMenu(to: menu, configuration: configuration, targets: [directory])
            }
        case .contextualMenuForItems, .contextualMenuForSidebar, .toolbarItemMenu:
            addMenuItemsForSelection(selectedURLs, targetedURL: targetedURL, to: menu, configuration: configuration)
        @unknown default:
            break
        }

        return menu
    }

    override func beginObservingDirectory(at url: URL) {
        logger.debug("Begin observing directory: \(url.path, privacy: .public)")
    }

    override func endObservingDirectory(at url: URL) {
        logger.debug("End observing directory: \(url.path, privacy: .public)")
    }

    private func addMenuItemsForSelection(
        _ selectedURLs: [URL],
        targetedURL: URL?,
        to menu: NSMenu,
        configuration: RightClickConfiguration
    ) {
        if let directory = RightClickTargetResolver.targetDirectory(
            selectedURLs: selectedURLs,
            targetedURL: targetedURL
        ) {
            addDirectoryItems(to: menu, directory: directory, configuration: configuration)
        }

        if let copyTargets = RightClickCopyTargetResolver.selectedItems(
            selectedURLs,
            targetedURL: targetedURL
        ) {
            addCopyItemsForSelection(to: menu, configuration: configuration, targets: copyTargets)
        }

        guard !selectedURLs.isEmpty else {
            return
        }

        addOpenWithMenu(to: menu, configuration: configuration, targets: selectedURLs)
    }

    private func addCopyItemsForSelection(
        to menu: NSMenu,
        configuration: RightClickConfiguration,
        targets: RightClickCopyTargets
    ) {
        if configuration.copyFileName {
            addCopyItem(
                title: localized("finder.copyFileName", defaultValue: "复制文件名", configuration: configuration),
                actionID: ActionID.copyFileName,
                to: menu,
                targets: targets
            )
        }

        addPathCopyItems(to: menu, configuration: configuration, targets: targets)
    }

    private func addPathCopyItems(
        to menu: NSMenu,
        configuration: RightClickConfiguration,
        targets: RightClickCopyTargets
    ) {
        if configuration.copyAbsolutePath {
            addCopyItem(
                title: localized("finder.copyAbsolutePath", defaultValue: "复制绝对路径", configuration: configuration),
                actionID: ActionID.copyAbsolutePath,
                to: menu,
                targets: targets
            )
        }
        if configuration.copyRelativePath {
            addCopyItem(
                title: localized("finder.copyRelativePath", defaultValue: "复制相对路径", configuration: configuration),
                actionID: ActionID.copyRelativePath,
                to: menu,
                targets: targets
            )
        }
        if configuration.copyShellEscapedPath {
            addCopyItem(
                title: localized("finder.copyShellEscapedPath", defaultValue: "复制转义路径", configuration: configuration),
                actionID: ActionID.copyShellEscapedPath,
                to: menu,
                targets: targets
            )
        }
        if configuration.copyFileURL {
            addCopyItem(
                title: localized("finder.copyFileURL", defaultValue: "复制 file:// 链接", configuration: configuration),
                actionID: ActionID.copyFileURL,
                to: menu,
                targets: targets
            )
        }
    }

    /// Directory-level items shared by container and item right-clicks.
    private func addDirectoryItems(to menu: NSMenu, directory: URL, configuration: RightClickConfiguration) {
        if configuration.newFolder {
            addNewFolderItem(to: menu, directory: directory, configuration: configuration)
        }
        if configuration.newFile {
            addNewFileMenu(to: menu, directory: directory, configuration: configuration)
        }
        if configuration.openInTerminal {
            addOpenInTerminalItem(to: menu, directory: directory, configuration: configuration)
        }
    }

    private func addNewFolderItem(to menu: NSMenu, directory: URL, configuration: RightClickConfiguration) {
        let item = actionItem(title: localized("finder.newFolder", defaultValue: "新建文件夹", configuration: configuration), context: MenuActionContext(
            actionID: ActionID.newFolder,
            directory: directory
        ))
        menu.addItem(item)
    }

    private func addNewFileMenu(to menu: NSMenu, directory: URL, configuration: RightClickConfiguration) {
        let title = localized("finder.newFile", defaultValue: "新建文件", configuration: configuration)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for ext in RightClickNewFile.supportedExtensions {
            let item = actionItem(
                title: Self.newFileItemTitle(for: ext, preferredLanguages: configuration.preferredLanguages),
                context: MenuActionContext(actionID: ActionID.newFile, directory: directory, fileExtension: ext)
            )
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private static func newFileItemTitle(for ext: String, preferredLanguages: [String]?) -> String {
        switch ext {
        case "txt": RightClickLocalization.string(
            "finder.newFile.text",
            defaultValue: "文本文件 (.txt)",
            preferredLanguages: preferredLanguages
        )
        case "md": "Markdown (.md)"
        case "csv": "CSV (.csv)"
        case "json": "JSON (.json)"
        case "yaml": "YAML (.yaml)"
        case "yml": "YAML (.yml)"
        case "xml": "XML (.xml)"
        case "html": "HTML (.html)"
        case "css": "CSS (.css)"
        case "js": "JavaScript (.js)"
        case "ts": "TypeScript (.ts)"
        case "sh": "Shell (.sh)"
        case "py": "Python (.py)"
        default: ".\(ext)"
        }
    }

    private func addOpenInTerminalItem(to menu: NSMenu, directory: URL, configuration: RightClickConfiguration) {
        let item = actionItem(title: localized("finder.openInTerminal", defaultValue: "在终端打开", configuration: configuration), context: MenuActionContext(
            actionID: ActionID.openInTerminal,
            directory: directory
        ))
        menu.addItem(item)
    }

    /// Adds an "open with" submenu for the configured apps that match at least one
    /// target's extension (an entry with no extension filter matches everything).
    private func addOpenWithMenu(to menu: NSMenu, configuration: RightClickConfiguration, targets: [URL]) {
        guard !configuration.openWithApps.isEmpty, !targets.isEmpty else {
            return
        }
        let matching = configuration.openWithApps.filter { app in
            targets.contains { app.matches(fileExtension: $0.pathExtension) }
        }
        guard !matching.isEmpty else {
            return
        }

        let title = localized("finder.openWith", defaultValue: "用应用打开", configuration: configuration)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        var usedTitles: Set<String> = []
        for app in matching {
            // Stable identity is appPath (carried in representedObject). Make the
            // displayed title unique too, so the title fallback (used when
            // FinderSync strips representedObject) still resolves to one app.
            var title = app.name
            if !usedTitles.insert(title).inserted {
                let folder = URL(fileURLWithPath: app.appPath).deletingLastPathComponent().lastPathComponent
                title = "\(app.name) — \(folder)"
                while !usedTitles.insert(title).inserted {
                    title += " ·"
                }
            }
            let item = actionItem(
                title: title,
                context: MenuActionContext(actionID: ActionID.openWith, appPath: app.appPath)
            )
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func localized(
        _ key: String,
        defaultValue: String,
        configuration: RightClickConfiguration
    ) -> String {
        RightClickLocalization.string(
            key,
            defaultValue: defaultValue,
            preferredLanguages: configuration.preferredLanguages
        )
    }

    private func addCopyItem(
        title: String,
        actionID: String,
        to menu: NSMenu,
        targets: RightClickCopyTargets
    ) {
        menu.addItem(actionItem(
            title: title,
            context: MenuActionContext(actionID: actionID, copyTargets: targets)
        ))
    }

    private func actionItem(title: String, context: MenuActionContext) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(handleMenuAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = context
        titleToActionContext[title] = context
        return item
    }

    @objc private func handleMenuAction(_ sender: NSMenuItem) {
        guard let context = menuActionContext(for: sender) else {
            logger.error("Missing action context for menu item: \(sender.title, privacy: .public)")
            return
        }

        switch context.actionID {
        case ActionID.newFolder:
            guard let directory = context.directory else { return }
            openHostURL(path: "/new-folder", queryItems: [
                URLQueryItem(name: "directory", value: directory.path)
            ])
        case ActionID.newFile:
            guard let directory = context.directory, let ext = context.fileExtension else { return }
            openHostURL(path: "/new-file", queryItems: [
                URLQueryItem(name: "directory", value: directory.path),
                URLQueryItem(name: "ext", value: ext)
            ])
        case ActionID.openInTerminal:
            guard let directory = context.directory else { return }
            openHostURL(path: "/open-terminal", queryItems: [
                URLQueryItem(name: "directory", value: directory.path)
            ])
        case ActionID.openWith:
            handleOpenWith(appPath: context.appPath)
        case ActionID.copyFileName:
            copyToPasteboard(RightClickPathFormatter.joinedFileNames(context.copyTargets?.urls ?? []))
        case ActionID.copyAbsolutePath:
            copyToPasteboard(RightClickPathFormatter.joinedPaths(context.copyTargets?.urls ?? []))
        case ActionID.copyRelativePath:
            copyToPasteboard(
                RightClickPathFormatter.joinedRelativePaths(
                    context.copyTargets?.urls ?? [],
                    base: context.copyTargets?.relativeBaseURL
                )
            )
        case ActionID.copyShellEscapedPath:
            copyToPasteboard(RightClickPathFormatter.joinedShellEscapedPaths(context.copyTargets?.urls ?? []))
        case ActionID.copyFileURL:
            copyToPasteboard(RightClickPathFormatter.joinedFileURLs(context.copyTargets?.urls ?? []))
        default:
            logger.error("Unknown action: \(context.actionID, privacy: .public)")
        }
    }

    /// Forward an open-with request to the host: resolve the app by its name from
    /// the current config (the menu item only carries the title), then send the
    /// app path and the target file paths.
    private func handleOpenWith(appPath: String?) {
        guard let appPath else { return }
        let configuration = RightClickConfigurationStore.load()
        guard let app = configuration.openWithApps.first(where: { $0.appPath == appPath }) else {
            logger.error("open-with: no configured app at \(appPath, privacy: .public)")
            return
        }
        let selected = currentSelectedURLs()
        let resolved = selected.isEmpty ? [currentTargetedURL()].compactMap { $0 } : selected
        // Only forward files this app actually applies to — a mixed selection may
        // include types its extension filter excludes.
        let targets = resolved.filter { app.matches(fileExtension: $0.pathExtension) }
        guard !targets.isEmpty else {
            logger.error("open-with: no matching target items for \(appPath, privacy: .public)")
            return
        }
        var queryItems = [URLQueryItem(name: "app", value: app.appPath)]
        queryItems += targets.map { URLQueryItem(name: "file", value: $0.path) }
        openHostURL(path: "/open-with", queryItems: queryItems)
    }

    private func menuActionContext(for item: NSMenuItem) -> MenuActionContext? {
        if let context = item.representedObject as? MenuActionContext {
            return context
        }

        // macOS can strip representedObject from Finder Sync menu items. Keep a
        // title fallback, mirroring SuperRClick's approach.
        return titleToActionContext[item.title]
    }

    private func currentSelectedURLs() -> [URL] {
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        return selectedURLs.isEmpty ? lastSelectedURLs : selectedURLs
    }

    private func currentTargetedURL() -> URL? {
        FIFinderSyncController.default().targetedURL() ?? lastTargetedURL
    }

    private func copyToPasteboard(_ value: String) {
        guard !value.isEmpty else {
            logger.error("Copy action skipped because copy targets are empty")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        guard pasteboard.setString(value, forType: .string) else {
            logger.error("Failed to write right-click value to pasteboard")
            return
        }
    }

    private func openHostURL(path: String, queryItems: [URLQueryItem]) {
        var components = URLComponents()
        components.scheme = hostURLScheme
        components.host = "right-click"
        components.path = path
        components.queryItems = queryItems

        guard let url = components.url else {
            logger.error("Failed to build host URL for \(path, privacy: .public)")
            return
        }

        NSWorkspace.shared.open(url)
    }

    private static func monitoredDirectories() -> Set<URL> {
        // Finder Sync only asks for menus inside monitored directories. A right-click
        // utility is expected to work from arbitrary Finder locations, so monitor the
        // filesystem root and let the menu builder stay lightweight.
        [URL(fileURLWithPath: "/", isDirectory: true)]
    }
}
