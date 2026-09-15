import AppKit
import ScreenCaptureKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelLayoutEditorRenderingTests: XCTestCase {
    func testCustomPanelEditorAndNormalLayoutPreviews() async throws {
        let suite = "CustomPanelPreviews.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = PluginHost(
            plugins: [
                LayoutRenderingPlugin("Clock", span: PluginComponentSpan(width: 2, height: 16)!, order: 0),
                LayoutRenderingPlugin("System", span: PluginComponentSpan(width: 2, height: 16)!, order: 1),
                LayoutRenderingPlugin("Clipboard", span: PluginComponentSpan(width: 4, height: 12)!, order: 2)
            ], shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults), globalShortcutManager: GlobalShortcutManager()
        )
        let id = try XCTUnwrap(host.addMenuBarPanel())
        _ = host.addMenuBarPanel()
        let emptyID = try XCTUnwrap(host.addMenuBarPanel())
        host.assignPanelEntry(pluginID: "Clock", surface: .dashboard, to: id)
        host.assignPanelEntry(pluginID: "System", surface: .dashboard, to: id)
        host.assignPanelEntry(pluginID: "System", surface: .featurePanel, to: id)
        host.assignPanelEntry(pluginID: "Clipboard", surface: .dashboard, to: id)
        host.setPluginVisible(false, id: "Clipboard", on: .dashboard)
        for (name, scheme, editing) in [("editing-light", ColorScheme.light, true), ("editing-dark", .dark, true),
                                         ("normal", .light, false), ("empty-editing", .light, true), ("empty-normal", .light, false)] {
            let previewID = name.hasPrefix("empty") ? emptyID : id
            let entries = host.panelEntries(in: previewID)
            let components = host.componentItems(in: previewID)
            let features = host.panelItems(in: previewID)
            let contentHeight = editing ? PanelLayoutDestination.editorContentHeight(
                itemHeight: ConfiguredMenuBarPanelLayout.placement(entries: entries, components: components, features: features).height,
                maximumHeight: 600
            ) : ConfiguredMenuBarPanelLayout.contentHeight(components: components, features: features, screen: nil, entries: entries)
            let model = MenuBarUnifiedPanelModel(selectedTab: MenuBarPanelTab(id: previewID), contentHeight: contentHeight,
                                                maximumFeatureListHeight: 600, isPanelVisible: true)
            model.onTabSelection = { tab in model.update(selectedTab: tab, contentHeight: contentHeight,
                maximumFeatureListHeight: 600, isPanelVisible: true) }
            if editing { model.beginLayoutEditing(visibleItemCount: 3) }
            let height = MenuBarPanelLayout.panelHeight(forContentHeight: contentHeight, showsEditingActionBar: editing)
            let updater = AppUpdater(startingUpdater: false)
            updater.setAvailableUpdateVersionForTests("9.9")
            let view = NSHostingView(rootView: MenuBarUnifiedPanelContent(
                pluginHost: host, appUpdater: updater,
                menuBarPanelThemeStore: MenuBarPanelThemeStore(userDefaults: defaults), model: model,
                onDismiss: {}, onOpenUpdate: {}, onOpenSettings: {},
                onPresentDiskCleanConfiguration: {}, onPresentLaunchControlConfiguration: {}
            ).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: MenuBarPanelLayout.baseWidth, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/mactools-custom-panel-\(name).png"))
            if editing && !name.hasPrefix("empty") {
                func sources(in root: NSView) -> [PanelLayoutDragSourceView] {
                    (root as? PanelLayoutDragSourceView).map { [$0] } ?? root.subviews.flatMap { sources(in: $0) }
                }
                for (surface, source) in [
                    ("card", sources(in: view).first { $0.identifier?.rawValue == "panel.layout.drag.dashboard:Clock" }),
                    ("feature", sources(in: view).first { $0.identifier?.rawValue == "panel.layout.drag.featurePanel:System" })
                ] {
                    let source = try XCTUnwrap(source)
                    let point = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
                    source.hover?.trackingView?.pointerLocationInWindow = { _ in point }
                    source.hover?.trackingView?.refresh()
                    try await Task.sleep(for: .milliseconds(180))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: "/private/tmp/mactools-custom-panel-\(name)-\(surface)-hover.png"))
                    do {
                        try await captureCompositedWindow(window, name: "\(name)-\(surface)-hover")
                    } catch {
                        // A logged-in WindowServer capture session is optional;
                        // the NSHostingView bitmap above is always validated.
                        add(XCTAttachment(string: "Optional composited capture unavailable: \(error)"))
                    }
                    source.hover?.trackingView?.pointerLocationInWindow = { _ in CGPoint(x: -10_000, y: -10_000) }
                    source.hover?.trackingView?.refresh()
                    try await Task.sleep(for: .milliseconds(180))
                }
            }
            model.onTabSelection = nil
        }
    }

    private func captureCompositedWindow(_ window: NSWindow, name: String) async throws {
        // cacheDisplay omits WindowServer filters such as blur. Capture only this
        // fixture's window when permission already exists; never request access.
        guard CGPreflightScreenCaptureAccess() else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                              configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/private/tmp/mactools-custom-panel-\(name)-composited.png"))
    }

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
