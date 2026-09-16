import AppKit

/// Shared native presentation for capture confirmation and active-session controls.
@MainActor
enum CaptureActionBar {
    static let insets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

    static func configure(_ button: NSButton, isPrimary: Bool = false) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13, weight: isPrimary ? .medium : .regular)
        if #available(macOS 26.0, *) {
            button.borderShape = .capsule
        }
    }

    static func make(_ views: [NSView], blending: NSVisualEffectView.BlendingMode = .withinWindow) -> NSView {
        let body = content(views)
        return Glass.wrap(body, radius: body.fittingSize.height / 2, blending: blending)
    }

    static func content(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8

        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
        ])
        return container
    }
}
