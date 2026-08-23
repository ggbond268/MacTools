import Foundation

@MainActor
final class CLIInstallationController: ObservableObject {
    static let shared = CLIInstallationController()

    enum Status: Equatable {
        case installed
        case notInstalled
        case conflict
        case unavailable
    }

    @Published private(set) var status: Status = .notInstalled
    @Published private(set) var lastError: String?

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let sourceURL: URL?

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledCLIURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.sourceURL = bundledCLIURL ?? Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("mactools")
        refresh()
    }

    var installURL: URL {
        homeDirectory.appendingPathComponent(".local/bin/mactools")
    }

    var bundledCLIURL: URL? {
        sourceURL
    }

    func install() {
        guard let source = bundledCLIURL,
              fileManager.isExecutableFile(atPath: source.path) else {
            lastError = "未找到随应用提供的命令行工具。"
            refresh()
            return
        }
        let directory = installURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            if fileManager.fileExists(atPath: installURL.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: installURL.path)) != nil {
                guard pointsToBundledCLI else {
                    lastError = "安装位置已有其他文件，请先移走 ~/.local/bin/mactools。"
                    refresh()
                    return
                }
                try fileManager.removeItem(at: installURL)
            }
            try fileManager.createSymbolicLink(at: installURL, withDestinationURL: source)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func uninstall() {
        guard pointsToBundledCLI else {
            lastError = "未移除：安装位置不是 MacTools 创建的链接。"
            refresh()
            return
        }
        do {
            try fileManager.removeItem(at: installURL)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        guard let bundledCLIURL else {
            status = .unavailable
            return
        }
        if pointsToBundledCLI {
            status = .installed
        } else if fileManager.fileExists(atPath: installURL.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: installURL.path)) != nil {
            status = .conflict
        } else if fileManager.isExecutableFile(atPath: bundledCLIURL.path) {
            status = .notInstalled
        } else {
            status = .unavailable
        }
    }

    private var pointsToBundledCLI: Bool {
        guard let source = bundledCLIURL,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: installURL.path)
        else { return false }
        let resolved: URL
        if destination.hasPrefix("/") {
            resolved = URL(fileURLWithPath: destination)
        } else {
            resolved = installURL.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return resolved.standardizedFileURL.resolvingSymlinksInPath()
            == source.standardizedFileURL.resolvingSymlinksInPath()
    }
}
