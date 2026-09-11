import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ClipboardHistoryPromiseBundle {
    let writers: [any NSPasteboardWriting]
    let delegates: [ClipboardHistoryFilePromiseDelegate]
}

@MainActor
enum ClipboardHistoryFilePromiseFactory {
    static func makeBundle(
        item: ClipboardHistoryItem,
        localization: PluginLocalization,
        onSuccess: @escaping @MainActor @Sendable () -> Void
    ) async -> ClipboardHistoryPromiseBundle? {
        guard let payload = try? await ClipboardHistoryExportService.loadPayload(for: item) else {
            return nil
        }
        defer { item.discardCachedPayloadIfReloadable() }
        if item.kind == .files {
            guard let urls = await ClipboardHistoryFileReferenceValidator.validate(
                urls: payload.fileURLs
            ) else { return nil }
            return ClipboardHistoryPromiseBundle(
                writers: urls.map { $0 as NSURL },
                delegates: []
            )
        }

        guard let format = ClipboardHistoryExportPlanner.defaultFormat(for: item) else { return nil }
        let baseName = ClipboardHistoryExportTitles.baseName(for: item, localization: localization)
        guard let plan = try? ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: format,
            baseName: baseName,
            markdownAttachmentDirectorySuffix: ClipboardHistoryExportTitles.markdownAttachmentDirectorySuffix(
                localization: localization
            ),
            markdownAttachmentBaseName: ClipboardHistoryExportTitles.markdownAttachmentBaseName(
                localization: localization
            )
        ) else { return nil }
        let names = promisedNames(payload: payload, plan: plan, baseName: baseName)
        guard names.count == plan.expectedArtifactCount else { return nil }
        let artifactLoader = ClipboardHistoryPromisedArtifactLoader(
            item: item,
            payload: payload,
            plan: plan,
            baseName: baseName
        )

        let delegates = names.enumerated().map { index, name in
            ClipboardHistoryFilePromiseDelegate(
                artifactLoader: artifactLoader,
                plan: plan,
                artifactIndex: index,
                promisedFileName: name.fileName,
                contentTypeIdentifier: name.typeIdentifier,
                onSuccess: onSuccess
            )
        }
        let writers: [any NSPasteboardWriting] = delegates.map { delegate in
            let provider = NSFilePromiseProvider(
                fileType: delegate.contentTypeIdentifier,
                delegate: delegate
            )
            provider.userInfo = delegate
            return provider
        }
        return ClipboardHistoryPromiseBundle(writers: writers, delegates: delegates)
    }

    private static func promisedNames(
        payload: ClipboardHistoryPayload,
        plan: ClipboardExportPlan,
        baseName: String
    ) -> [(fileName: String, typeIdentifier: String)] {
        if plan.format == .original, payload.kind == .media {
            let representations = ClipboardHistoryExportPlanner.matchingItems(in: payload) {
                ClipboardHistoryExportPlanner.exportableMediaType(for: $0.typeIdentifier) != nil
            }.compactMap { item in
                item.representations.first(where: {
                    ClipboardHistoryExportPlanner.exportableMediaType(for: $0.typeIdentifier) != nil
                })
            }
            return representations.enumerated().compactMap { index, representation in
                guard let type = UTType(representation.typeIdentifier),
                      let fileExtension = type.preferredFilenameExtension else { return nil }
                return (
                    ClipboardHistoryExportNaming.fileName(
                        baseName: baseName,
                        extension: fileExtension,
                        index: representations.count > 1 ? index + 1 : nil
                    ),
                    type.identifier
                )
            }
        }

        let fileExtension = URL(fileURLWithPath: plan.suggestedName).pathExtension
        let typeIdentifier = plan.contentTypeIdentifier ?? UTType.data.identifier
        return (0..<plan.expectedArtifactCount).map { index in
            (
                ClipboardHistoryExportNaming.fileName(
                    baseName: baseName,
                    extension: fileExtension,
                    index: plan.expectedArtifactCount > 1 ? index + 1 : nil
                ),
                typeIdentifier
            )
        }
    }
}

final class ClipboardHistoryFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let contentTypeIdentifier: String

    private let artifactLoader: ClipboardHistoryPromisedArtifactLoader
    private let plan: ClipboardExportPlan
    private let artifactIndex: Int
    private let promisedFileName: String
    private let onSuccess: @MainActor @Sendable () -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.mactools.clipboard-history.file-promise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(
        artifactLoader: ClipboardHistoryPromisedArtifactLoader,
        plan: ClipboardExportPlan,
        artifactIndex: Int,
        promisedFileName: String,
        contentTypeIdentifier: String,
        onSuccess: @escaping @MainActor @Sendable () -> Void
    ) {
        self.artifactLoader = artifactLoader
        self.plan = plan
        self.artifactIndex = artifactIndex
        self.promisedFileName = promisedFileName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.onSuccess = onSuccess
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        promisedFileName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = ClipboardHistoryFilePromiseCompletion(completionHandler)
        Task {
            do {
                let artifacts = try await artifactLoader.artifacts()
                guard artifacts.indices.contains(artifactIndex) else {
                    throw ClipboardExportError.invalidPayload
                }
                let artifact = artifacts[artifactIndex]
                let singlePlan = ClipboardExportPlan(
                    itemID: plan.itemID,
                    format: plan.format,
                    destination: .file,
                    suggestedName: promisedFileName,
                    contentTypeIdentifier: contentTypeIdentifier,
                    expectedArtifactCount: 1,
                    markdownAttachmentDirectorySuffix: plan.markdownAttachmentDirectorySuffix,
                    markdownAttachmentBaseName: plan.markdownAttachmentBaseName
                )
                try await Task.detached(priority: .userInitiated) {
                    try Self.writeCoordinated(
                        artifact: artifact,
                        plan: singlePlan,
                        destinationURL: url
                    )
                }.value
                await onSuccess()
                completion.call(nil)
            } catch {
                completion.call(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    private static func writeCoordinated(
        artifact: ClipboardExportArtifact,
        plan: ClipboardExportPlan,
        destinationURL: URL
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: (any Error)?
        coordinator.coordinate(
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                _ = try ClipboardHistoryExportService.write(
                    artifacts: [artifact],
                    plan: plan,
                    destinationURL: coordinatedURL
                )
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordinationError { throw coordinationError }
    }
}

enum ClipboardHistoryFileReferenceValidator {
    typealias FileExistenceCheck = @Sendable (URL) -> Bool

    static func validate(
        urls: [URL],
        fileExists: @escaping FileExistenceCheck = { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    ) async -> [URL]? {
        guard !urls.isEmpty else { return nil }
        do {
            let validated: [URL]? = try await ClipboardHistoryExportAsyncWork.run {
                for url in urls {
                    try Task.checkCancellation()
                    guard fileExists(url) else { return nil }
                }
                return urls
            }
            guard !Task.isCancelled else { return nil }
            return validated
        } catch {
            return nil
        }
    }
}

actor ClipboardHistoryPromisedArtifactLoader {
    private let item: ClipboardHistoryItem
    private let payload: ClipboardHistoryPayload
    private let plan: ClipboardExportPlan
    private let baseName: String
    private var task: Task<[ClipboardExportArtifact], any Error>?

    init(
        item: ClipboardHistoryItem,
        payload: ClipboardHistoryPayload,
        plan: ClipboardExportPlan,
        baseName: String
    ) {
        self.item = item
        self.payload = payload
        self.plan = plan
        self.baseName = baseName
    }

    func artifacts() async throws -> [ClipboardExportArtifact] {
        if let task { return try await task.value }
        let item = item
        let payload = payload
        let plan = plan
        let baseName = baseName
        let task = Task {
            try await ClipboardHistoryExportService.makeArtifacts(
                item: item,
                payload: payload,
                plan: plan,
                baseName: baseName
            )
        }
        self.task = task
        do {
            return try await task.value
        } catch {
            self.task = nil
            throw error
        }
    }
}

private final class ClipboardHistoryFilePromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func call(_ error: Error?) {
        handler(error)
    }
}

@MainActor
struct ClipboardHistoryDragSource: NSViewRepresentable {
    let item: ClipboardHistoryItem
    let localization: PluginLocalization
    let onSuccess: @MainActor @Sendable () -> Void

    func makeNSView(context: Context) -> ClipboardHistoryDragSourceView {
        let view = ClipboardHistoryDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ClipboardHistoryDragSourceView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ClipboardHistoryDragSourceView) {
        view.makeBundle = {
            await ClipboardHistoryFilePromiseFactory.makeBundle(
                item: item,
                localization: localization,
                onSuccess: onSuccess
            )
        }
    }
}

@MainActor
final class ClipboardHistoryDragSourceView: NSView, NSDraggingSource {
    var makeBundle: (() async -> ClipboardHistoryPromiseBundle?)?
    private var retainedDelegates: [ClipboardHistoryFilePromiseDelegate] = []
    private var pendingBundleTask: Task<Void, Never>?
    private var startedDragging = false

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        pendingBundleTask?.cancel()
        pendingBundleTask = nil
        startedDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging, let makeBundle else { return }
        startedDragging = true
        pendingBundleTask = Task { @MainActor [weak self, event] in
            guard let self, let bundle = await makeBundle(), !Task.isCancelled,
                  !bundle.writers.isEmpty else {
                self?.startedDragging = false
                return
            }
            retainedDelegates = bundle.delegates
            let location = convert(event.locationInWindow, from: nil)
            let items = bundle.writers.enumerated().map { index, writer in
                let draggingItem = NSDraggingItem(pasteboardWriter: writer)
                let offset = CGFloat(index) * 3
                draggingItem.setDraggingFrame(
                    NSRect(x: location.x + offset, y: location.y - 16 - offset, width: 32, height: 32),
                    contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                )
                return draggingItem
            }
            pendingBundleTask = nil
            beginDraggingSession(with: items, event: event, source: self)
        }
    }

    override func mouseUp(with event: NSEvent) {
        pendingBundleTask?.cancel()
        pendingBundleTask = nil
        if retainedDelegates.isEmpty { startedDragging = false }
        super.mouseUp(with: event)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        retainedDelegates = []
        pendingBundleTask = nil
        startedDragging = false
    }
}
