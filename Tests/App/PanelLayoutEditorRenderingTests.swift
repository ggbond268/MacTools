import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelLayoutEditorRenderingTests: XCTestCase {
    func testEditorRenderFixtures() async throws {
        let suite = "PanelLayoutEditorRenderingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = PluginHost(
            plugins: [
                LayoutRenderingPlugin("Clock", span: PluginComponentSpan(width: 1, height: 12)!, order: 0),
                LayoutRenderingPlugin("System Status", span: PluginComponentSpan(width: 2, height: 24)!, order: 1),
                LayoutRenderingPlugin("Calendar", span: PluginComponentSpan(width: 1, height: 24)!, order: 2),
                LayoutRenderingPlugin("Clipboard", span: PluginComponentSpan(width: 4, height: 24)!, order: 3)
            ],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        for (name, surface, direction, scheme, contrast) in [
            ("dashboard", PluginDisplaySurface.dashboard, LayoutDirection.leftToRight, ColorScheme.light, ColorSchemeContrast.standard),
            ("features", .featurePanel, .leftToRight, .light, .standard),
            ("dashboard-rtl-contrast", .dashboard, .rightToLeft, .dark, .increased)
        ] {
            let theme = MenuBarPanelThemeResolver.resolve(definition: nil, colorScheme: scheme, contrast: contrast)
            let view = NSHostingView(rootView:
                PanelLayoutEditor(pluginHost: host, surface: surface, onDismiss: {})
                    .environment(\.layoutDirection, direction)
                    .environment(\.colorScheme, scheme)
                    .environment(\.menuBarPanelTheme, theme)
                    .padding(12)
                    .frame(width: ComponentPanelLayout.panelWidth, height: 520)
                    .background(theme.surfaces.panel)
            )
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: ComponentPanelLayout.panelWidth, height: 520),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .accessibilityHighContrastDarkAqua : .aqua)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            view.layoutSubtreeIfNeeded()
            // Capture the real hosted views for visual review. In-process NSHostingView
            // traversal does not reliably populate SwiftUI's external accessibility tree.
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }


}

@MainActor
private final class LayoutRenderingPlugin: MacToolsPlugin, PluginComponentPanel, PluginPrimaryPanel {
    let metadata: PluginMetadata
    let descriptor: PluginComponentDescriptor
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(controlStyle: .switch, menuActionBehavior: .keepPresented)
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(_ title: String, span: PluginComponentSpan, order: Int) {
        metadata = PluginMetadata(id: title, title: title, iconName: "square.grid.2x2", iconTint: .blue,
                                  order: order, defaultDescription: title)
        descriptor = PluginComponentDescriptor(span: span)
    }

    var componentPanelState: PluginComponentState {
        .init(subtitle: "", isActive: true, isEnabled: true, isVisible: true, errorMessage: nil)
    }

    var primaryPanelState: PluginPanelState {
        .init(subtitle: "", isOn: true, isExpanded: false, isEnabled: true, isVisible: true, detail: nil, errorMessage: nil)
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            Text(metadata.title).font(.headline)
            Text("42").font(.largeTitle.monospacedDigit())
            Button("Forbidden Live Action") { XCTFail("Reordering invoked a plugin action") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)))
    }

    func handleAction(_ action: PluginPanelAction) { XCTFail("Editing invoked a plugin action") }
}
