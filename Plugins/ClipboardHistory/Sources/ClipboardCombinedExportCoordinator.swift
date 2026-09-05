import AppKit
import Foundation
import MacToolsPluginKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardCombinedExportCoordinator {
    private let historyController: ClipboardHistoryController
    private let localization: PluginLocalization
    private weak var hudPresenter: (any ClipboardPrivacyHUDPresenting)?
    private weak var activePanel: NSSavePanel?
    private var task: Task<Void, Never>?

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
        task?.cancel()
        activePanel?.cancel(nil)
        activePanel = nil
    }

    func export(itemIDs: [UUID], format: ClipboardExportFormat, parentWindow: NSWindow?) {
        guard [.plainText, .markdown, .html, .pdf].contains(format), !itemIDs.isEmpty else {
            return
        }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self,
                  let text = await self.historyController.combinedPlainText(ids: itemIDs) else {
                return
            }
            do {
                let data = try await self.data(text: text, format: format)
                try Task.checkCancellation()
                guard let destination = await self.chooseDestination(
                    format: format,
                    parentWindow: parentWindow
                ) else { return }
                try Task.checkCancellation()
                let destinationSnapshot = try ClipboardHistoryExportService.destinationSnapshot(
                    at: destination
                )
                let contentTypeIdentifier = self.contentType(for: format).identifier
                let artifact = ClipboardExportArtifact(
                    relativePath: destination.lastPathComponent,
                    contentTypeIdentifier: contentTypeIdentifier,
                    data: data
                )
                let plan = ClipboardExportPlan(
                    itemID: itemIDs[0],
                    format: format,
                    destination: .file,
                    suggestedName: destination.lastPathComponent,
                    contentTypeIdentifier: contentTypeIdentifier,
                    expectedArtifactCount: 1
                )
                try await ClipboardHistoryExportAsyncWork.runCommitting {
                    _ = try ClipboardHistoryExportService.writeExplicitFile(
                        artifacts: [artifact],
                        plan: plan,
                        destinationURL: destination,
                        expectedDestination: destinationSnapshot
                    )
                }
                self.historyController.recordCombinedItemUsage(ids: itemIDs)
                self.hudPresenter?.showSuccess(self.localization.string(
                    "export.combined.success",
                    defaultValue: "Combined selection exported"
                ))
            } catch is CancellationError {
                return
            } catch {
                self.hudPresenter?.showFailure(self.localization.string(
                    "export.failure",
                    defaultValue: "Export failed"
                ))
            }
        }
    }

    func export(
        text: String,
        itemIDs: [UUID],
        historyItemIDs: [UUID],
        format: ClipboardExportFormat,
        parentWindow: NSWindow?
    ) {
        guard [.plainText, .markdown, .html, .pdf].contains(format),
              !itemIDs.isEmpty,
              !text.isEmpty else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await self.data(text: text, format: format)
                try Task.checkCancellation()
                guard let destination = await self.chooseDestination(
                    format: format,
                    parentWindow: parentWindow
                ) else { return }
                let snapshot = try ClipboardHistoryExportService.destinationSnapshot(at: destination)
                let contentTypeIdentifier = self.contentType(for: format).identifier
                let artifact = ClipboardExportArtifact(
                    relativePath: destination.lastPathComponent,
                    contentTypeIdentifier: contentTypeIdentifier,
                    data: data
                )
                let plan = ClipboardExportPlan(
                    itemID: itemIDs[0],
                    format: format,
                    destination: .file,
                    suggestedName: destination.lastPathComponent,
                    contentTypeIdentifier: contentTypeIdentifier,
                    expectedArtifactCount: 1
                )
                try await ClipboardHistoryExportAsyncWork.runCommitting {
                    _ = try ClipboardHistoryExportService.writeExplicitFile(
                        artifacts: [artifact],
                        plan: plan,
                        destinationURL: destination,
                        expectedDestination: snapshot
                    )
                }
                self.historyController.recordCombinedItemUsage(ids: historyItemIDs)
                self.hudPresenter?.showSuccess(self.localization.string(
                    "export.combined.success",
                    defaultValue: "Combined selection exported"
                ))
            } catch is CancellationError {
                return
            } catch {
                self.hudPresenter?.showFailure(self.localization.string(
                    "export.failure",
                    defaultValue: "Export failed"
                ))
            }
        }
    }

    private func data(text: String, format: ClipboardExportFormat) async throws -> Data {
        switch format {
        case .plainText, .markdown:
            return Data(text.utf8)
        case .html:
            return Data(Self.HTMLDocument(text: text).utf8)
        case .pdf:
            return try await ClipboardPDFExporter().render(html: Self.HTMLDocument(text: text))
        default:
            throw ClipboardExportError.unsupportedRepresentation
        }
    }

    private func chooseDestination(
        format: ClipboardExportFormat,
        parentWindow: NSWindow?
    ) async -> URL? {
        let panel = NSSavePanel()
        activePanel = panel
        defer { activePanel = nil }
        let fileExtension: String
        let contentType = contentType(for: format)
        switch format {
        case .plainText:
            fileExtension = "txt"
        case .markdown:
            fileExtension = "md"
        case .html:
            fileExtension = "html"
        case .pdf:
            fileExtension = "pdf"
        default:
            return nil
        }
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Combined Clipboard.\(fileExtension)"
        panel.message = localization.string(
            "export.combined.message",
            defaultValue: "Export the selected clipboard items as one document."
        )
        if let parentWindow {
            PluginPresentationSafety.prepareForWindowOrdering(panel)
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: parentWindow) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func contentType(for format: ClipboardExportFormat) -> UTType {
        switch format {
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
        case .html:
            return .html
        case .pdf:
            return .pdf
        default:
            return .plainText
        }
    }

    nonisolated static func HTMLDocument(text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font: 15px -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; }
        pre { white-space: pre-wrap; overflow-wrap: anywhere; }
        </style></head><body><pre>\(escaped)</pre></body></html>
        """
    }
}
