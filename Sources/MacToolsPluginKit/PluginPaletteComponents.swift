import AppKit
import SwiftUI

public enum PluginPaletteMetrics {
    public static let surfaceCornerRadius: CGFloat = 14
    public static let contentPadding: CGFloat = 16
    public static let contentSpacing: CGFloat = 12
    public static let searchCornerRadius: CGFloat = 9
    public static let searchHorizontalPadding: CGFloat = 12
    public static let searchVerticalPadding: CGFloat = 9
    public static let searchContentSpacing: CGFloat = 8
    public static let searchToolbarSpacing: CGFloat = 8
    public static let toolbarControlSize = CGSize(width: 40, height: 40)
    public static let rowCornerRadius: CGFloat = 8
    public static let rowHorizontalPadding: CGFloat = 10
    public static let rowVerticalPadding: CGFloat = 9
    public static let rowIconWidth: CGFloat = 18
    public static let rowContentSpacing: CGFloat = 12
    public static let rowTitleDescriptionSpacing: CGFloat = 3
    public static let footerTopPadding: CGFloat = 8
}

public enum PluginPaletteSearchCommand: Equatable {
    case moveSelection(offset: Int)
    case submit
    case alternateSubmit
    case cancel
}

public struct PluginPaletteSearchField: NSViewRepresentable {
    @Binding private var text: String
    private let placeholder: String
    private let accessibilityLabel: String
    private let accessibilityIdentifier: String
    private let focusRequestID: UInt
    private let alternateSubmitModifier: NSEvent.ModifierFlags?
    private let onCommand: (PluginPaletteSearchCommand) -> Void

    public init(
        text: Binding<String>,
        placeholder: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        focusRequestID: UInt,
        alternateSubmitModifier: NSEvent.ModifierFlags? = nil,
        onCommand: @escaping (PluginPaletteSearchCommand) -> Void
    ) {
        _text = text
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.focusRequestID = focusRequestID
        self.alternateSubmitModifier = alternateSubmitModifier
        self.onCommand = onCommand
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSTextField {
        let field = SearchTextField()
        field.onAlternateSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCommand(.alternateSubmit)
        }
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        field.lineBreakMode = .byTruncatingTail
        configure(field)
        context.coordinator.focus(field, for: focusRequestID)
        return field
    }

    public func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        configure(field)
        if field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.focus(field, for: focusRequestID)
    }

    public static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.cancelPendingFocus()
    }

    private func configure(_ field: NSTextField) {
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        guard let field = field as? SearchTextField else { return }
        field.alternateSubmitModifier = alternateSubmitModifier
    }

    public static func command(
        for selector: Selector,
        hasMarkedText: Bool,
        modifierFlags: NSEvent.ModifierFlags = [],
        alternateSubmitModifier: NSEvent.ModifierFlags? = nil
    ) -> PluginPaletteSearchCommand? {
        guard !hasMarkedText else { return nil }

        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            return .moveSelection(offset: 1)
        case #selector(NSResponder.moveUp(_:)):
            return .moveSelection(offset: -1)
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            return matchesAlternateSubmit(
                modifierFlags: modifierFlags,
                alternateSubmitModifier: alternateSubmitModifier
            )
                ? .alternateSubmit
                : .submit
        case #selector(NSResponder.cancelOperation(_:)):
            return .cancel
        default:
            return nil
        }
    }

    public static func isAlternateSubmitKeyEquivalent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        alternateSubmitModifier: NSEvent.ModifierFlags?
    ) -> Bool {
        guard let alternateSubmitModifier else { return false }
        let isReturn = keyCode == 36 || keyCode == 76
        return isReturn && matchesAlternateSubmit(
            modifierFlags: modifierFlags,
            alternateSubmitModifier: alternateSubmitModifier
        )
    }

    private static func matchesAlternateSubmit(
        modifierFlags: NSEvent.ModifierFlags,
        alternateSubmitModifier: NSEvent.ModifierFlags?
    ) -> Bool {
        guard let alternateSubmitModifier else { return false }
        let actual = normalizedModifiers(modifierFlags)
        let expected = normalizedModifiers(alternateSubmitModifier)
        if expected == .command {
            return actual.contains(.command) && actual.isDisjoint(with: [.control, .option])
        }
        return actual == expected
    }

    private static func normalizedModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }

    @MainActor
    public final class SearchTextField: NSTextField {
        fileprivate var alternateSubmitModifier: NSEvent.ModifierFlags?
        fileprivate var onAlternateSubmit: (() -> Void)?

        public override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if PluginPaletteSearchField.isAlternateSubmitKeyEquivalent(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                alternateSubmitModifier: alternateSubmitModifier
            ) {
                onAlternateSubmit?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextFieldDelegate {
        private static let maximumFocusAttemptCount = 25
        private static let focusRetryDelay = Duration.milliseconds(20)

        var parent: PluginPaletteSearchField
        private var completedFocusRequestID: UInt?
        private var pendingFocusRequestID: UInt?
        private var focusTask: Task<Void, Never>?
        private let focusClaim: @MainActor (NSTextField) -> Bool

        init(
            parent: PluginPaletteSearchField,
            focusClaim: (@MainActor (NSTextField) -> Bool)? = nil
        ) {
            self.parent = parent
            self.focusClaim = focusClaim ?? Self.claimFocus
        }

        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        public func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            guard let command = PluginPaletteSearchField.command(
                for: selector,
                hasMarkedText: textView.hasMarkedText(),
                modifierFlags: NSApp.currentEvent?.modifierFlags ?? [],
                alternateSubmitModifier: parent.alternateSubmitModifier
            ) else {
                return false
            }
            parent.onCommand(command)
            return true
        }

        func focus(_ field: NSTextField, for requestID: UInt) {
            guard completedFocusRequestID != requestID,
                  pendingFocusRequestID != requestID else {
                return
            }

            focusTask?.cancel()
            pendingFocusRequestID = requestID
            focusTask = Task { @MainActor [weak self, weak field] in
                guard let self, let field else { return }

                for attempt in 0 ..< Self.maximumFocusAttemptCount {
                    guard !Task.isCancelled,
                          pendingFocusRequestID == requestID else {
                        return
                    }

                    if focusClaim(field) {
                        completedFocusRequestID = requestID
                        pendingFocusRequestID = nil
                        focusTask = nil
                        return
                    }

                    guard attempt + 1 < Self.maximumFocusAttemptCount else {
                        break
                    }
                    if attempt == 0 {
                        await Task.yield()
                    } else {
                        try? await Task.sleep(for: Self.focusRetryDelay)
                    }
                }

                if pendingFocusRequestID == requestID {
                    pendingFocusRequestID = nil
                    focusTask = nil
                }
            }
        }

        func cancelPendingFocus() {
            focusTask?.cancel()
            focusTask = nil
            pendingFocusRequestID = nil
        }

        private static func claimFocus(_ field: NSTextField) -> Bool {
            guard let window = field.window,
                  window.isVisible,
                  window.isKeyWindow,
                  window.makeFirstResponder(field) else {
                return false
            }
            return field.currentEditor() != nil
        }
    }
}

public struct PluginPaletteSearchBar: View {
    @Binding private var text: String
    private let placeholder: String
    private let accessibilityLabel: String
    private let accessibilityIdentifier: String
    private let clearAccessibilityLabel: String
    private let focusRequestID: UInt
    private let alternateSubmitModifier: NSEvent.ModifierFlags?
    private let onCommand: (PluginPaletteSearchCommand) -> Void

    public init(
        text: Binding<String>,
        placeholder: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        clearAccessibilityLabel: String,
        focusRequestID: UInt,
        alternateSubmitModifier: NSEvent.ModifierFlags? = nil,
        onCommand: @escaping (PluginPaletteSearchCommand) -> Void
    ) {
        _text = text
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.clearAccessibilityLabel = clearAccessibilityLabel
        self.focusRequestID = focusRequestID
        self.alternateSubmitModifier = alternateSubmitModifier
        self.onCommand = onCommand
    }

    public var body: some View {
        HStack(spacing: PluginPaletteMetrics.searchContentSpacing) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            PluginPaletteSearchField(
                text: $text,
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                focusRequestID: focusRequestID,
                alternateSubmitModifier: alternateSubmitModifier,
                onCommand: onCommand
            )
            .frame(maxWidth: .infinity, minHeight: 22)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(clearAccessibilityLabel)
                .accessibilityLabel(clearAccessibilityLabel)
            }

        }
        .padding(.horizontal, PluginPaletteMetrics.searchHorizontalPadding)
        .padding(.vertical, PluginPaletteMetrics.searchVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: PluginPaletteMetrics.searchCornerRadius, style: .continuous)
                .fill(PluginSettingsTheme.Palette.fieldBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PluginPaletteMetrics.searchCornerRadius, style: .continuous)
                .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
        }
    }
}

public struct PluginPaletteSearchToolbar<Controls: View>: View {
    private let searchBar: PluginPaletteSearchBar
    private let controls: Controls

    public init(
        text: Binding<String>,
        placeholder: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        clearAccessibilityLabel: String,
        focusRequestID: UInt,
        alternateSubmitModifier: NSEvent.ModifierFlags? = nil,
        onCommand: @escaping (PluginPaletteSearchCommand) -> Void,
        @ViewBuilder controls: () -> Controls
    ) {
        searchBar = PluginPaletteSearchBar(
            text: text,
            placeholder: placeholder,
            accessibilityLabel: accessibilityLabel,
            accessibilityIdentifier: accessibilityIdentifier,
            clearAccessibilityLabel: clearAccessibilityLabel,
            focusRequestID: focusRequestID,
            alternateSubmitModifier: alternateSubmitModifier,
            onCommand: onCommand
        )
        self.controls = controls()
    }

    public var body: some View {
        HStack(spacing: PluginPaletteMetrics.searchToolbarSpacing) {
            searchBar
            controls
        }
    }
}

public struct PluginPaletteSurface: View {
    private let reducesTransparency: Bool
    private let backgroundColor: Color

    public init(
        reducesTransparency: Bool,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    ) {
        self.reducesTransparency = reducesTransparency
        self.backgroundColor = backgroundColor
    }

    public var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: PluginPaletteMetrics.surfaceCornerRadius,
            style: .continuous
        )
        shape
            .fill(
                reducesTransparency
                    ? AnyShapeStyle(backgroundColor)
                    : AnyShapeStyle(.regularMaterial)
            )
            .overlay {
                if !reducesTransparency {
                    shape.fill(backgroundColor.opacity(0.88))
                }
            }
    }
}

public struct PluginPaletteSelectableRowModifier: ViewModifier {
    private let isSelected: Bool
    @State private var isHovered = false

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, PluginPaletteMetrics.rowHorizontalPadding)
            .padding(.vertical, PluginPaletteMetrics.rowVerticalPadding)
            .background(
                RoundedRectangle(
                    cornerRadius: PluginPaletteMetrics.rowCornerRadius,
                    style: .continuous
                )
                .fill(rowBackground)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private var rowBackground: Color {
        if isSelected {
            return .accentColor
        }
        return isHovered ? Color.primary.opacity(0.09) : .clear
    }
}

public struct PluginPaletteToolbarControlStyle: ButtonStyle {
    private let size: CGSize

    @Environment(\.isEnabled) private var isEnabled

    public init(size: CGSize = PluginPaletteMetrics.toolbarControlSize) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        PluginPaletteToolbarControlStyleBody(
            configuration: configuration,
            size: size,
            isEnabled: isEnabled
        )
    }
}

private struct PluginPaletteToolbarControlStyleBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGSize
    let isEnabled: Bool
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .frame(width: size.width, height: size.height)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(
                background,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private var background: Color {
        if configuration.isPressed {
            return PluginSettingsTheme.Palette.fieldBackground.opacity(0.7)
        }
        if isHovered, isEnabled {
            return PluginSettingsTheme.Palette.activeControlBackground
        }
        return PluginSettingsTheme.Palette.fieldBackground
    }
}

public extension View {
    func pluginPaletteSelectableRow(isSelected: Bool) -> some View {
        modifier(PluginPaletteSelectableRowModifier(isSelected: isSelected))
    }
}

public struct PluginPaletteKeyboardHint: View {
    private let key: String
    private let action: String

    public init(key: String, action: String) {
        self.key = key
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    PluginSettingsTheme.Palette.fieldBackground,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
                }
            Text(action)
        }
        .accessibilityElement(children: .combine)
    }
}

public struct PluginPaletteFooter<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    public init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack {
            leading
            Spacer()
            trailing
        }
        .font(PluginSettingsTheme.Typography.secondaryLabel)
        .foregroundStyle(.secondary)
        .padding(.top, PluginPaletteMetrics.footerTopPadding)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
