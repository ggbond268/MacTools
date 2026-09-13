import AppKit
import SwiftUI
import MacToolsPluginKit

@MainActor
enum WindowSwitcherAppearance {
    static func increasedContrast(_ appearance: NSAppearance) -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || appearance.name == .accessibilityHighContrastAqua
            || appearance.name == .accessibilityHighContrastDarkAqua
    }

    static func selectionColor(_ appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(increasedContrast(appearance) ? 0.40 : (dark ? 0.26 : 0.16))
    }

    static func highlighted(_ text: String, ranges: [NSRange]) -> NSAttributedString {
        let value = NSMutableAttributedString(string: text)
        for range in ranges {
            // Treat the match as a color pair: inherited dark-mode label colors
            // are not readable on the system's yellow find highlight.
            value.addAttributes([.backgroundColor: NSColor.yellow, .foregroundColor: NSColor.black], range: range)
        }
        return value
    }
}

/// Layer colors must refresh when appearance, accent, or accessibility changes.
@MainActor
class WindowSwitcherAppearanceView: NSView {
    nonisolated(unsafe) private var colorObserver: NSObjectProtocol?
    nonisolated(unsafe) private var accessibilityObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        colorObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAppearance() }
            }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAppearance() }
            }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let colorObserver { NotificationCenter.default.removeObserver(colorObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() { needsDisplay = true }
}

/// Match the command palette's shared field and toolbar geometry without
/// replacing the switcher's native search responder and input-method handling.
@MainActor
private func drawPaletteField(in bounds: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                            xRadius: PluginPaletteMetrics.searchCornerRadius,
                            yRadius: PluginPaletteMetrics.searchCornerRadius)
    NSColor.textBackgroundColor.setFill(); path.fill()
    NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
}

@MainActor
final class WindowSwitcherHeaderSurface: NSView {
    var isFocused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        drawPaletteField(in: bounds)
        if isFocused {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                   xRadius: PluginPaletteMetrics.searchCornerRadius,
                                   yRadius: PluginPaletteMetrics.searchCornerRadius)
            NSColor.keyboardFocusIndicatorColor.setStroke()
            ring.lineWidth = 2; ring.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
final class WindowSwitcherToolbarButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

/// Match Clipboard History's flat scope treatment with one rendering path.
/// Native buttons avoid the system picker's single-segment text-color bug.
@MainActor
final class WindowSwitcherScopeControl: NSControl {
    private let model = WindowSwitcherScopePickerModel()
    private var hostingView: NSHostingView<WindowSwitcherScopePicker>!
    var segmentCount: Int {
        get { model.count }
        set {
            guard model.count != newValue else { return }
            model.count = newValue
            if newValue == 1 { selectedSegment = 0 }
            invalidateIntrinsicContentSize()
        }
    }
    var selectedSegment: Int {
        get { model.selection }
        set { if model.selection != newValue { model.selection = newValue } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hostingView = NSHostingView(rootView: WindowSwitcherScopePicker(model: model))
        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren([hostingView!])
        model.onSelection = { [weak self] index in self?.selectScope(at: index) }
    }
    required init?(coder: NSCoder) { nil }

    func setLabel(_ title: String, forSegment index: Int) {
        guard model.titles[index] != title else { return }
        model.titles[index] = title
        invalidateIntrinsicContentSize()
    }
    func label(forSegment index: Int) -> String? { model.titles[index] }
    func setEnabled(_ enabled: Bool, forSegment index: Int) {
        if model.enabled[index] != enabled { model.enabled[index] = enabled }
    }
    func isEnabled(forSegment index: Int) -> Bool { model.enabled[index] }
    func setToolTip(_ title: String?, forSegment index: Int) {
        if model.help[index] != title { model.help[index] = title }
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: model.width, height: 24)
    }
    func selectScope(at index: Int) {
        guard (0..<model.count).contains(index), model.enabled[index] else { return }
        selectedSegment = index
        sendAction(action, to: target)
    }
}

@MainActor
private final class WindowSwitcherScopePickerModel: ObservableObject {
    @Published var titles = ["", ""]
    @Published var help: [String?] = [nil, nil]
    @Published var enabled = [true, true]
    @Published var count = 2
    @Published var selection = 0
    var onSelection: ((Int) -> Void)?
    var width: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return titles.prefix(count).reduce(CGFloat.zero) {
            $0 + ceil(($1 as NSString).size(withAttributes: [.font: font]).width) + 24
        }
    }
}

private struct WindowSwitcherScopePicker: View {
    @ObservedObject var model: WindowSwitcherScopePickerModel
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<model.count, id: \.self) { index in
                Button { model.onSelection?(index) } label: {
                    Text(model.titles[index])
                        .font(.system(size: NSFont.systemFontSize))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .foregroundStyle(model.selection == index ? Color.white : Color.primary)
                        .background(model.selection == index ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.help[index] ?? model.titles[index])
                .disabled(!model.enabled[index])
                .accessibilityAddTraits(model.selection == index ? [.isSelected] : [])
            }
        }
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: model.width, height: 24, alignment: .leading)
        .accessibilityIdentifier("window-switcher-scope-picker")
    }
}
