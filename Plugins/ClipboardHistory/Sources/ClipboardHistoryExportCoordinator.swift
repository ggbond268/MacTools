import AppKit
import Foundation
import MacToolsPluginKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardHistoryExportCoordinator {
    private let historyController: ClipboardHistoryController
    private let localization: PluginLocalization
    private weak var hudPresenter: (any ClipboardPrivacyHUDPresenting)?
    private let operationRegistry = ClipboardHistoryExportOperationRegistry()
    private weak var activePanel: NSSavePanel?

    init(
        historyController: ClipboardHistoryController,
        localization: PluginLocalization,
        hudPresenter: any ClipboardPrivacyHUDPresenting
    ) {
        self.historyController = historyController
        self.localization = localization
        self.hudPresenter = hudPresenter
    }

    func cancel() {
        operationRegistry.cancel()
        activePanel?.cancel(nil)
        activePanel = nil
    }

    func export(itemID: UUID, format: ClipboardExportFormat, parentWindow: NSWindow?) {
        guard operationRegistry.isIdle,
              let item = historyController.items.first(where: { $0.id == itemID }) else {
            return
        }
        let baseName = ClipboardHistoryExportTitles.baseName(for: item, localization: localization)
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.historyController.releasePayloadIfReloadable(id: itemID)
                self.finishOperation(id: operationID)
            }
            do {
                let payload = try await ClipboardHistoryExportService.loadPayload(for: item)
                try Task.checkCancellation()
                let plan = try await ClipboardHistoryExportAsyncWork.run {
                    try ClipboardHistoryExportPlanner.makePlan(
                        item: item,
                    payload: payload,
                    format: format,
                    baseName: baseName,
                    markdownAttachmentDirectorySuffix: ClipboardHistoryExportTitles.markdownAttachmentDirectorySuffix(
                        localization: self.localization
                    ),
                    markdownAttachmentBaseName: ClipboardHistoryExportTitles.markdownAttachmentBaseName(
                        localization: self.localization
                    )
                    )
                }
                try Task.checkCancellation()
                guard let destinationURL = await self.chooseDestination(
                    for: plan,
                    parentWindow: parentWindow
                ) else { return }
                try Task.checkCancellation()
                let expectedDestination: ClipboardExportDestinationSnapshot? = try await ClipboardHistoryExportAsyncWork.run {
                    guard plan.destination == .file else { return nil }
                    return try ClipboardHistoryExportService.destinationSnapshot(at: destinationURL)
                }
                let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
                    item: item,
                    payload: payload,
                    plan: plan,
                    baseName: baseName
                )
                try Task.checkCancellation()
                let writtenURLs: [URL]
                if let expectedDestination {
                    writtenURLs = try await ClipboardHistoryExportAsyncWork.runCommitting {
                        try ClipboardHistoryExportService.writeExplicitFile(
                            artifacts: artifacts,
                            plan: plan,
                            destinationURL: destinationURL,
                            expectedDestination: expectedDestination
                        )
                    }
                } else {
                    writtenURLs = try await ClipboardHistoryExportAsyncWork.run {
                        try ClipboardHistoryExportService.write(
                            artifacts: artifacts,
                            plan: plan,
                            destinationURL: destinationURL
                        )
                    }
                    try Task.checkCancellation()
                }
                guard !writtenURLs.isEmpty else { throw ClipboardExportError.unavailable }
                self.historyController.recordSuccessfulUse(id: itemID)
                self.hudPresenter?.showSuccess(self.localization.format(
                    "export.success",
                    defaultValue: "已导出 %lld 个文件",
                    writtenURLs.count
                ))
            } catch is CancellationError {
                return
            } catch {
                self.hudPresenter?.showFailure(self.localizedError(error))
            }
        }
        operationRegistry.install(id: operationID, task: task)
    }

    func showReferencedFiles(itemID: UUID) {
        guard operationRegistry.isIdle,
              let item = historyController.items.first(where: { $0.id == itemID }) else {
            return
        }
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.historyController.releasePayloadIfReloadable(id: itemID)
                self.finishOperation(id: operationID)
            }
            do {
                let payload = try await ClipboardHistoryExportService.loadPayload(for: item)
                try Task.checkCancellation()
                let urls = try await self.availableReferencedFiles(payload.fileURLs)
                try Task.checkCancellation()
                guard !urls.isEmpty else { throw ClipboardExportError.missingReferencedFile }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                self.historyController.recordSuccessfulUse(id: itemID)
            } catch is CancellationError {
                return
            } catch {
                self.hudPresenter?.showFailure(self.localizedError(error))
            }
        }
        operationRegistry.install(id: operationID, task: task)
    }

    func copyReferencedFiles(itemID: UUID, parentWindow: NSWindow?) {
        guard operationRegistry.isIdle,
              let item = historyController.items.first(where: { $0.id == itemID }) else {
            return
        }
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.historyController.releasePayloadIfReloadable(id: itemID)
                self.finishOperation(id: operationID)
            }
            do {
                let payload = try await ClipboardHistoryExportService.loadPayload(for: item)
                try Task.checkCancellation()
                let sourceURLs = try await self.availableReferencedFiles(payload.fileURLs)
                try Task.checkCancellation()
                guard !sourceURLs.isEmpty else { throw ClipboardExportError.missingReferencedFile }
                guard let directory = await self.chooseFolder(parentWindow: parentWindow) else { return }
                try Task.checkCancellation()
                let copied = try await ClipboardHistoryExportAsyncWork.run {
                    try Self.copy(sourceURLs: sourceURLs, to: directory)
                }
                try Task.checkCancellation()
                guard !copied.isEmpty else { throw ClipboardExportError.unavailable }
                self.historyController.recordSuccessfulUse(id: itemID)
                self.hudPresenter?.showSuccess(self.localization.format(
                    "export.copy.success",
                    defaultValue: "已复制 %lld 个文件",
                    copied.count
                ))
            } catch is CancellationError {
                return
            } catch {
                self.hudPresenter?.showFailure(self.localizedError(error))
            }
        }
        operationRegistry.install(id: operationID, task: task)
    }

    private func chooseDestination(
        for plan: ClipboardExportPlan,
        parentWindow: NSWindow?
    ) async -> URL? {
        switch plan.destination {
        case .file:
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = plan.suggestedName
            panel.message = localization.string(
                "export.save.message",
                defaultValue: "将此剪贴板项目导出到文件。"
            )
            if let identifier = plan.contentTypeIdentifier, let type = UTType(identifier) {
                panel.allowedContentTypes = [type]
            }
            return await run(panel: panel, parentWindow: parentWindow)
        case .folder:
            return await chooseFolder(parentWindow: parentWindow)
        }
    }

    private func chooseFolder(parentWindow: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = localization.string("export.chooseFolder", defaultValue: "选择文件夹")
        panel.message = localization.string(
            "export.folder.message",
            defaultValue: "选择保存导出文件的文件夹。"
        )
        return await run(panel: panel, parentWindow: parentWindow)
    }

    private func run(panel: NSSavePanel, parentWindow: NSWindow?) async -> URL? {
        activePanel = panel
        defer {
            if activePanel === panel {
                activePanel = nil
            }
        }
        if let parentWindow {
            return await withCheckedContinuation { continuation in
                PluginPresentationSafety.prepareForWindowOrdering()
                panel.beginSheetModal(for: parentWindow) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
        PluginPresentationSafety.prepareForWindowOrdering()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func availableReferencedFiles(_ urls: [URL]) async throws -> [URL] {
        try await ClipboardHistoryExportAsyncWork.run {
            guard !urls.isEmpty else { throw ClipboardExportError.unavailable }
            for url in urls where !FileManager.default.fileExists(atPath: url.path) {
                try Task.checkCancellation()
                throw ClipboardExportError.missingReferencedFile
            }
            return urls
        }
    }

    private func finishOperation(id: UUID) {
        operationRegistry.finish(id: id)
    }

    nonisolated static func copy(
        sourceURLs: [URL],
        to directory: URL,
        fileManager: FileManager = .default,
        copyItem: ((URL, URL) throws -> Void)? = nil
    ) throws -> [URL] {
        var copied: [URL] = []
        var stagedURL: URL?
        let copyOperation = copyItem ?? { source, destination in
            try fileManager.copyItem(at: source, to: destination)
        }
        do {
            for sourceURL in sourceURLs {
                try Task.checkCancellation()
                let destination = try ClipboardHistoryExportNaming.availableURL(
                    in: directory,
                    preferredFileName: sourceURL.lastPathComponent,
                    fileManager: fileManager
                )
                let stage = directory.appendingPathComponent(
                    ".mactools-copy-\(UUID().uuidString)",
                    isDirectory: sourceURL.hasDirectoryPath
                )
                stagedURL = stage
                try copyOperation(sourceURL, stage)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw ClipboardExportError.unsafeDestination
                }
                try fileManager.moveItem(at: stage, to: destination)
                stagedURL = nil
                copied.append(destination)
            }
            try Task.checkCancellation()
            return copied
        } catch {
            if let stagedURL { try? fileManager.removeItem(at: stagedURL) }
            for url in copied { try? fileManager.removeItem(at: url) }
            throw error
        }
    }

    private func localizedError(_ error: any Error) -> String {
        switch error as? ClipboardExportError {
        case .missingReferencedFile:
            localization.string("export.error.missingFile", defaultValue: "原始文件已不可用")
        case .recognizedTextUnavailable:
            localization.string("export.error.noRecognizedText", defaultValue: "未识别到可导出的文本")
        case .unsupportedRepresentation:
            localization.string("export.error.unsupported", defaultValue: "此剪贴板格式无法导出")
        default:
            localization.string("export.error.failed", defaultValue: "无法导出剪贴板项目")
        }
    }
}

enum ClipboardHistoryExportTitles {
    static func markdownAttachmentDirectorySuffix(localization: PluginLocalization) -> String {
        localization.string("export.filename.assets", defaultValue: "附件")
    }

    static func markdownAttachmentBaseName(localization: PluginLocalization) -> String {
        localization.string("export.filename.attachment", defaultValue: "附件")
    }

    static func baseName(
        for item: ClipboardHistoryItem,
        localization: PluginLocalization
    ) -> String {
        let localizedKind = switch item.kind {
        case .plainText:
            localization.string("export.filename.text", defaultValue: "剪贴板文本")
        case .richText:
            localization.string("export.filename.richText", defaultValue: "剪贴板富文本")
        case .image:
            localization.string("export.filename.image", defaultValue: "剪贴板图像")
        case .pdf:
            localization.string("export.filename.pdf", defaultValue: "剪贴板 PDF")
        case .files:
            localization.string("export.filename.files", defaultValue: "剪贴板文件")
        case .link:
            localization.string("export.filename.link", defaultValue: "剪贴板链接")
        case .color:
            localization.string("export.filename.color", defaultValue: "剪贴板颜色")
        case .media:
            localization.string("export.filename.media", defaultValue: "剪贴板媒体")
        }
        return localizedKind + " " + ClipboardHistoryExportNaming.capturedTimestamp(item.capturedAt)
    }
    static func format(_ format: ClipboardExportFormat, localization: PluginLocalization) -> String {
        switch format {
        case .plainText: localization.string("export.format.plainText", defaultValue: "纯文本")
        case .html: localization.string("export.format.html", defaultValue: "HTML")
        case .pdf: localization.string("export.format.pdf", defaultValue: "PDF")
        case .markdown: localization.string("export.format.markdown", defaultValue: "Markdown")
        case .original: localization.string("export.format.original", defaultValue: "原始格式")
        case .png: localization.string("export.format.png", defaultValue: "PNG")
        case .jpeg: localization.string("export.format.jpeg", defaultValue: "JPEG")
        case .tiff: localization.string("export.format.tiff", defaultValue: "TIFF")
        case .webLocation: localization.string("export.format.webLocation", defaultValue: "网页位置")
        case .recognizedText: localization.string("export.format.recognizedText", defaultValue: "识别的文本")
        }
    }
}
