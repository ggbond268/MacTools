import AppKit

@MainActor
enum Glass {
    /// Uses native glass when available and a visual-effect fallback on older systems.
    static func wrap(_ content: NSView, radius: CGFloat, tint: NSColor? = nil,
                     blending: NSVisualEffectView.BlendingMode = .withinWindow) -> NSView {
        let box: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .regular
            glass.tintColor = tint
            glass.contentView = content
            box = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = blending
            effect.state = .active
            let diameter = radius * 2 + 1
            let mask = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            mask.resizingMode = .stretch
            effect.maskImage = mask
            if let tint {
                let layer = NSView(frame: .zero)
                layer.wantsLayer = true
                layer.layer?.backgroundColor = tint.withAlphaComponent(0.85).cgColor
                layer.autoresizingMask = [.width, .height]
                effect.addSubview(layer)
            }
            effect.addSubview(content)
            box = effect
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            content.topAnchor.constraint(equalTo: box.topAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    static func container(_ content: NSView, spacing: CGFloat) -> NSView {
        guard #available(macOS 26, *) else { return content }
        let container = NSGlassEffectContainerView()
        container.spacing = spacing
        container.contentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}
