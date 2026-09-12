import AppKit

@MainActor
final class AIAssistantPanelWindow: NSPanel {
    var onCloseRequest: (() -> Void)?

    private var isProgrammaticClose = false

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private var presentationTime: Date = .distantPast

    func markPresented() {
        presentationTime = Date()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        requestClose()
    }

    override func resignKey() {
        super.resignKey()

        guard isVisible, !isProgrammaticClose else { return }
        guard Date().timeIntervalSince(presentationTime) > 0.4 else { return }
        requestClose()
    }

    func performProgrammaticClose(_ close: () -> Void) {
        isProgrammaticClose = true
        close()
        isProgrammaticClose = false
    }

    private func requestClose() {
        onCloseRequest?()
    }
}
