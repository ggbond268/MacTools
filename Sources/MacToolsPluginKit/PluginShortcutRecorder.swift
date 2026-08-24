import AppKit
import SwiftUI

public enum PluginShortcutRecordingResult: Equatable {
    case accepted
    case rejected(String)

    public static func from(errorMessage: String?) -> PluginShortcutRecordingResult {
        if let errorMessage {
            return .rejected(errorMessage)
        }

        return .accepted
    }
}

enum PluginShortcutRecorderValidation {
    static func missingModifierMessage(for binding: ShortcutBinding) -> String? {
        guard !binding.hasRequiredModifiers else {
            return nil
        }

        return ShortcutValidationError.missingModifier.localizedDescription
    }
}

@MainActor
private final class PluginShortcutRecorderDisplayState: ObservableObject {
    @Published var previewText = PluginKitLocalization.shortcutRecorderPreviewPlaceholder
    @Published private(set) var showEscHint = false
    @Published private(set) var conflictMessage: String?
    @Published private(set) var shakeOffset: CGFloat = 0
    @Published private(set) var isShaking = false

    func triggerShake(conflict: String? = nil) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            showEscHint = true
            if let conflict {
                conflictMessage = conflict
            }
        }

        isShaking = true
        let steps: [(CGFloat, Double)] = [
            (10, 0.00), (-8, 0.06), (7, 0.12), (-5, 0.18), (3, 0.24), (0, 0.30)
        ]

        for (offset, delay) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                withAnimation(.linear(duration: 0.05)) {
                    self?.shakeOffset = offset
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
            self?.isShaking = false
        }
    }
}

public struct PluginShortcutRecorderField: View {
    public let displayText: String
    public let placeholder: String
    public let isRecording: Bool
    public let minWidth: CGFloat

    private var normalizedText: String {
        if displayText.isEmpty || displayText == "None" {
            return placeholder
        }

        return displayText
    }

    private var isPlaceholderVisible: Bool {
        normalizedText == placeholder
    }

    public init(
        displayText: String,
        placeholder: String = PluginKitLocalization.defaultShortcutPlaceholder,
        isRecording: Bool,
        minWidth: CGFloat = 90
    ) {
        self.displayText = displayText
        self.placeholder = placeholder
        self.isRecording = isRecording
        self.minWidth = minWidth
    }

    public var body: some View {
        PluginShortcutRecorderFieldContent(
            normalizedText: normalizedText,
            isPlaceholderVisible: isPlaceholderVisible,
            isRecording: isRecording,
            minWidth: minWidth
        )
    }
}

private struct PluginShortcutRecorderFieldContent: View {
    let normalizedText: String
    let isPlaceholderVisible: Bool
    let isRecording: Bool
    let minWidth: CGFloat

    @Environment(\.controlSize) private var controlSize

    private var isCompact: Bool {
        controlSize == .mini
    }

    private var height: CGFloat {
        isCompact ? 24 : PluginSettingsTheme.Size.controlHeight
    }

    private var horizontalPadding: CGFloat {
        isCompact ? 6 : PluginSettingsTheme.Spacing.sectionHeaderContent
    }

    private var textFont: Font {
        isCompact
            ? .system(size: 11, design: .monospaced)
            : PluginSettingsTheme.Typography.monospacedValue
    }

    var body: some View {
        Text(normalizedText)
            .font(textFont)
            .foregroundStyle(isPlaceholderVisible ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, horizontalPadding)
            .frame(
                minWidth: minWidth,
                minHeight: height,
                maxHeight: height,
                alignment: .center
            )
            .background(
                RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                    .fill(PluginSettingsTheme.Palette.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                    .strokeBorder(
                        isRecording ? Color.accentColor : PluginSettingsTheme.Palette.cardBorder,
                        lineWidth: isRecording ? 1.5 : PluginSettingsTheme.Stroke.standard
                    )
            )
    }
}

public struct PluginShortcutRecorder: View {
    public let title: String
    public let displayText: String
    public let placeholder: String
    public let minWidth: CGFloat
    public let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    public let onBeginRecording: (() -> Void)?
    public let onEndRecording: (() -> Void)?

    @State private var isPresented = false
    // PluginKit v5 ABI compatibility: this stored property must remain on the public
    // wrapper, in this order, because released plugins construct this view directly.
    @State private var isHovered = false

    public init(
        title: String,
        displayText: String,
        placeholder: String = PluginKitLocalization.defaultShortcutPlaceholder,
        minWidth: CGFloat = 90,
        onRecord: @escaping (ShortcutBinding) -> PluginShortcutRecordingResult,
        onBeginRecording: (() -> Void)? = nil,
        onEndRecording: (() -> Void)? = nil
    ) {
        self.title = title
        self.displayText = displayText
        self.placeholder = placeholder
        self.minWidth = minWidth
        self.onRecord = onRecord
        self.onBeginRecording = onBeginRecording
        self.onEndRecording = onEndRecording
    }

    public var body: some View {
        PluginShortcutRecorderButton(
            title: title,
            displayText: displayText,
            placeholder: placeholder,
            minWidth: minWidth,
            isPresented: $isPresented,
            isHovered: $isHovered,
            onRecord: onRecord,
            onBeginRecording: onBeginRecording,
            onEndRecording: onEndRecording
        )
    }
}

private struct PluginShortcutRecorderButton: View {
    let title: String
    let displayText: String
    let placeholder: String
    let minWidth: CGFloat
    @Binding var isPresented: Bool
    @Binding var isHovered: Bool
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    let onBeginRecording: (() -> Void)?
    let onEndRecording: (() -> Void)?

    var body: some View {
        Button {
            isPresented = true
        } label: {
            PluginShortcutRecorderField(
                displayText: displayText,
                placeholder: placeholder,
                isRecording: isPresented,
                minWidth: minWidth
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(
            cornerRadius: PluginSettingsTheme.Radius.field,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(isHovered && !isPresented ? 0.45 : 0),
                    lineWidth: PluginSettingsTheme.Stroke.standard
                )
                .allowsHitTesting(false)
        }
        .help(PluginKitLocalization.shortcutRecorderHelp(title: title))
        .accessibilityLabel(Text(title))
        .onHover { hovering in
            isHovered = hovering
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onDisappear {
            guard isHovered else { return }
            isHovered = false
            NSCursor.arrow.set()
        }
        .background {
            GeometryReader { proxy in
                PluginShortcutRecorderPopoverAnchor(
                    isPresented: $isPresented,
                    onRecord: onRecord,
                    onBeginRecording: onBeginRecording,
                    onEndRecording: onEndRecording
                )
                .frame(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))
                .allowsHitTesting(false)
            }
        }
    }
}

private struct PluginShortcutRecorderPopoverView: View {
    @ObservedObject var displayState: PluginShortcutRecorderDisplayState

    var body: some View {
        VStack(spacing: 0) {
            Text(displayState.previewText)
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowContentControl)
                .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
                .frame(minWidth: 130, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                        .fill(
                            displayState.isShaking
                                ? Color.red.opacity(0.18)
                                : PluginSettingsTheme.Palette.recordingBackground
                        )
                )
                .offset(x: displayState.shakeOffset)

            if displayState.conflictMessage != nil || displayState.showEscHint {
                Group {
                    if let message = displayState.conflictMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    } else {
                        Text(PluginKitLocalization.shortcutRecorderEscHint)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(PluginSettingsTheme.Typography.statusBadge)
                .padding(.top, PluginSettingsTheme.Spacing.controlCluster)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -6)),
                    removal: .opacity
                ))
            }
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowContentControl)
        .frame(minWidth: 160)
    }
}

private struct PluginShortcutRecorderPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    var onBeginRecording: (() -> Void)?
    var onEndRecording: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            isPresented: isPresented,
            sourceView: nsView,
            onRecord: onRecord,
            onDismiss: { isPresented = false },
            onBeginRecording: onBeginRecording,
            onEndRecording: onEndRecording
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private var popover: NSPopover?
        private var displayState: PluginShortcutRecorderDisplayState?
        private var keyMonitor: Any?
        private var committed = false
        private var wantsPresentation = false
        private var presentationRetryScheduled = false
        private var onRecord: ((ShortcutBinding) -> PluginShortcutRecordingResult)?
        private var onDismiss: (() -> Void)?
        private var onBeginRecording: (() -> Void)?
        private var onEndRecording: (() -> Void)?

        func update(
            isPresented: Bool,
            sourceView: NSView,
            onRecord: @escaping (ShortcutBinding) -> PluginShortcutRecordingResult,
            onDismiss: @escaping () -> Void,
            onBeginRecording: (() -> Void)?,
            onEndRecording: (() -> Void)?
        ) {
            wantsPresentation = isPresented
            self.onRecord = onRecord
            self.onDismiss = onDismiss
            self.onBeginRecording = onBeginRecording
            self.onEndRecording = onEndRecording

            if isPresented {
                requestPresentation(from: sourceView)
            } else if popover != nil {
                close()
            }
        }

        func close() {
            wantsPresentation = false

            guard let popover else {
                cleanup()
                return
            }

            let dismiss = onDismiss
            let endRecording = onEndRecording
            let wasRecording = displayState != nil

            popover.delegate = nil
            self.popover = nil
            popover.close()
            cleanup()
            dismiss?()
            if wasRecording {
                endRecording?()
            }
        }

        func popoverShouldClose(_ popover: NSPopover) -> Bool {
            guard !committed else { return true }
            displayState?.triggerShake()
            return false
        }

        private func requestPresentation(from sourceView: NSView) {
            guard wantsPresentation, popover == nil else {
                return
            }

            guard sourceView.window != nil, sourceView.bounds.width > 0, sourceView.bounds.height > 0 else {
                schedulePresentationRetry(from: sourceView)
                return
            }

            present(from: sourceView)
        }

        private func schedulePresentationRetry(from sourceView: NSView) {
            guard !presentationRetryScheduled else {
                return
            }

            presentationRetryScheduled = true
            DispatchQueue.main.async { [weak self, weak sourceView] in
                guard let self else { return }
                self.presentationRetryScheduled = false
                guard let sourceView else { return }
                self.requestPresentation(from: sourceView)
            }
        }

        private func present(from sourceView: NSView) {
            committed = false
            let state = PluginShortcutRecorderDisplayState()
            displayState = state

            onBeginRecording?()

            let content = PluginShortcutRecorderPopoverView(displayState: state)
            let controller = NSHostingController(rootView: content)
            controller.view.layoutSubtreeIfNeeded()

            let popover = NSPopover()
            popover.contentViewController = controller
            popover.contentSize = controller.view.fittingSize
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            self.popover = popover

            keyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: NSEvent.EventTypeMask.keyDown
                    .union(.flagsChanged)
                    .union(.leftMouseDown)
                    .union(.rightMouseDown)
                    .union(.otherMouseDown)
                    .union(.leftMouseUp)
                    .union(.rightMouseUp)
                    .union(.otherMouseUp)
                    .union(.scrollWheel)
                    .union(.mouseEntered)
                    .union(.mouseExited)
                    .union(.mouseMoved)
            ) { [weak self] event in
                guard let self else { return event }
                return self.handleEvent(event)
            }

            let anchorBounds = sourceView.bounds
            PluginPresentationSafety.prepareForWindowOrdering()
            popover.show(relativeTo: anchorBounds, of: sourceView, preferredEdge: .maxY)
        }

        private func handleEvent(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .flagsChanged:
                handleFlagsChanged(event)
                return event
            case .keyDown:
                return handleKey(event)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown,
                 .leftMouseUp, .rightMouseUp, .otherMouseUp,
                 .scrollWheel, .mouseEntered, .mouseExited, .mouseMoved:
                return nil
            default:
                return event
            }
        }

        private func handleFlagsChanged(_ event: NSEvent) {
            guard popover?.isShown == true else { return }
            let modifiers = ShortcutModifiers.from(event.modifierFlags)

            displayState?.previewText = modifiers.isEmpty
                ? PluginKitLocalization.shortcutRecorderPreviewPlaceholder
                : modifiers.symbolString.map { String($0) }.joined(separator: " + ")
        }

        private func handleKey(_ event: NSEvent) -> NSEvent? {
            guard popover?.isShown == true else { return event }

            let modifiers = ShortcutModifiers.from(event.modifierFlags)

            if event.keyCode == ShortcutKeyCode.escape, modifiers.isEmpty {
                close()
                return nil
            }

            let binding = ShortcutBinding(keyCode: event.keyCode, modifiers: modifiers)
            if let message = PluginShortcutRecorderValidation.missingModifierMessage(for: binding) {
                displayState?.triggerShake(conflict: message)
                return nil
            }

            guard binding.isValid else { return nil }

            switch onRecord?(binding) ?? .accepted {
            case .accepted:
                committed = true
                close()
            case let .rejected(message):
                displayState?.triggerShake(conflict: message)
            }

            return nil
        }

        private func cleanup() {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
            }

            keyMonitor = nil
            displayState = nil
            committed = false
            presentationRetryScheduled = false
            onRecord = nil
            onDismiss = nil
            onBeginRecording = nil
            onEndRecording = nil
        }
    }
}
