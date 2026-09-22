// Synthetic interfaces keep native interaction acceptance independent of installed
// plugins and user data. The runner appends the unmodified production UI sources.
import AppKit
import Combine
import MacToolsPluginKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

enum AppLog { static let panelLayout = Logger(subsystem: "com.mactools.panel-layout-fixture", category: "PanelLayout") }
struct Theme {
    struct Surfaces {
        let card = Color.gray.opacity(0.2)
        let panel = Color.white
        let control = Color.gray.opacity(0.15)
        let hover = Color.gray
        let selected = Color.gray.opacity(0.3)
        let tabSelection = Color.gray
        let separator = Color.gray.opacity(0.4)
    }
    struct Texts {
        let primary = Color.black
        let secondary = Color.gray
        let tertiary = Color.gray.opacity(0.8)
        let disabled = Color.gray.opacity(0.5)
        let onAccent = Color.white
    }
    struct Status { let warning = Color.orange; let critical = Color.red }
    let surfaces = Surfaces()
    let text = Texts()
    let accent = Color.blue
    let prominentControlFill = Color.blue
    let status = Status()
}
typealias MenuBarPanelThemeStyle = Theme
struct ThemeKey: EnvironmentKey { static let defaultValue = Theme() }
extension EnvironmentValues {
    var menuBarPanelTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
enum FeatureL10n {
    static func string(_ value: String) -> String { value }
    static func format(_ value: String, _ args: CVarArg...) -> String { String(format: value, arguments: args) }
}
enum AppL10n {
    static func search(_ s: String, defaultValue: String) -> String { defaultValue }
    static func plugins(_ s: String, defaultValue: String) -> String { defaultValue }
    static func settings(_ s: String, defaultValue: String) -> String { defaultValue }
    static func settingsFormat(_ s: String, defaultValue: String, _ args: CVarArg...) -> String {
        String(format: defaultValue, arguments: args)
    }
}
enum FixtureSurface {
    case dashboard, featurePanel
    var panelID: String { self == .dashboard ? "components" : "features" }
}

// Every storage access stays in memory; the real layout store never sees user preferences.
private final class FixtureDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

// XCTest covers the real feature renderer. Native drag acceptance only needs
// a row with the same geometry and inert callback contract.
struct FeatureRowView: View {
    let item: PluginPanelRowSnapshot
    let indicator: PluginPanelRowIndicator?
    let compactIndicator: PluginPanelRowCompactIndicator?
    let onDisclosureToggle: (Bool) -> Void
    let onSelectionChange: (String, String) -> Void
    let onNavigationSelectionChange: (String, String) -> Void
    let onNavigationHoverChange: (String, String, Bool) -> Void
    let onNavigationRowFrameChange: (String, String, CGRect?) -> Void
    let onDateChange: (String, Date) -> Void
    let onSwitchChange: (Bool) -> Bool
    let onSliderChange: (String, Double, PluginPanelAction.SliderPhase) -> Void
    let onActionInvoke: (String, PluginMenuActionBehavior) -> Void

    var body: some View {
        HStack {
            Image(systemName: item.iconName)
            Text(item.title)
            Spacer()
            Toggle("", isOn: Binding(get: { true }, set: { _ = onSwitchChange($0) }))
        }.padding(8)
    }
}
struct MenuBarPanelLayoutEntry: Identifiable {
    struct Item {
        let title: String
        let iconName = "circle"
    }
    let item: Item
    let entry: MenuBarPanelEntry
    var id: String { entry.id }
}
@MainActor final class PluginHost: ObservableObject {
    private let store = MenuBarPanelStore(userDefaults: FixtureDefaults())
    private let spans: [String: PluginPanelWidgetSpan]
    init(pluginIDs: [String] = ["a", "b", "c"], compact: Bool = false) {
        spans = compact ? Dictionary(uniqueKeysWithValues: pluginIDs.map {
            ($0, PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact)!)
        }) : ["a": .init(width: 2, height: 12)!, "b": .init(width: 1, height: 24)!,
              "c": .init(width: 4, height: 12)!]
        for id in pluginIDs {
            store.addItem(.init(pluginID: id, itemID: "widget"), to: "components")
            store.addItem(.init(pluginID: id, itemID: "control"), to: "features")
        }
    }
    var configuration: MenuBarPanelConfiguration {
        get { store.configuration }
        set { objectWillChange.send(); store.replace(newValue) }
    }
    var menuBarPanels: [MenuBarPanelDefinition] { configuration.panels }
    var visibleMenuBarPanels: [MenuBarPanelDefinition] { menuBarPanels }
    func rowIndicator(for id: String) -> PluginPanelRowIndicator? { nil }
    func rowCompactIndicator(for id: String) -> PluginPanelRowCompactIndicator? { nil }
    func componentItems(in id: String) -> [PluginPanelWidgetSnapshot] {
        panelEntries(in: id).filter { $0.kind == .widget }.map { entry in
            .init(id: entry.id, title: entry.pluginID, iconName: "circle", iconTint: .blue,
                  description: "", helpText: "", descriptionTone: .secondary,
                  span: spans[entry.pluginID]!, isActive: false, isEnabled: true, pluginID: entry.pluginID)
        }
    }
    func panelItems(in id: String) -> [PluginPanelRowSnapshot] {
        panelEntries(in: id).filter { $0.kind == .row }.map { entry in
            .init(id: entry.id, title: entry.pluginID, iconName: "circle", iconTint: .blue,
                  controlStyle: .switch, menuActionBehavior: .keepPresented, description: "", helpText: "",
                  descriptionTone: .secondary, isOn: true, isExpanded: false, isEnabled: true,
                  detail: nil, buttonActionID: nil, buttonTitle: nil, pluginID: entry.pluginID)
        }
    }
    func panelEntries(in id: String) -> [MenuBarPanelEntry] {
        configuration.placementsByPanelID[id, default: []].map {
            .init(placement: $0, kind: $0.item.itemID == "widget" ? .widget : .row)
        }
    }
    func panelLayoutEntries(in id: String) -> [MenuBarPanelLayoutEntry] {
        panelEntries(in: id).map { .init(item: .init(title: $0.pluginID), entry: $0) }
    }
    func movePanelEntry(_ entry: MenuBarPanelEntry, panelID: String, toOffset: Int) {
        let ids = PanelLayoutDestination.moving(entry.id, toOffset: toOffset, in: panelEntries(in: panelID).map(\.id))
        objectWillChange.send()
        store.setOrder(ids.compactMap(UUID.init(uuidString:)), panelID: panelID)
    }
    func removePanelEntry(_ entry: MenuBarPanelEntry, from panelID: String) -> Bool {
        guard panelEntries(in: panelID).contains(entry) else { return false }
        objectWillChange.send()
        store.removePlacement(id: entry.placement.id)
        return true
    }

    func transferPanelEntry(_ entry: MenuBarPanelEntry, from source: String, to destination: String,
                            at offset: Int) -> MenuBarPanelLayoutChange? {
        guard panelEntries(in: source).contains(entry) else { return nil }
        var ids = panelEntries(in: destination).map(\.placement.id)
        ids.insert(entry.placement.id, at: min(max(offset, 0), ids.count))
        let before = configuration
        objectWillChange.send()
        store.movePlacement(id: entry.placement.id, to: destination, visibleOrder: ids)
        return MenuBarPanelLayoutChange(before: before, after: configuration)
    }
    func canUndoPanelLayoutChange(_ change: MenuBarPanelLayoutChange) -> Bool { configuration == change.after }
    func undoPanelLayoutChange(_ change: MenuBarPanelLayoutChange) -> Bool {
        guard canUndoPanelLayoutChange(change) else { return false }
        configuration = change.before
        return true
    }
    func componentViewItem(for id: String, dismiss: @escaping () -> Void) -> PluginPanelWidgetViewItem {
        PluginPanelWidgetViewItem(id: id,
            content: AnyView(Text(id).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.blue.opacity(0.15))))
    }
}
struct MenuBarPanelTab: Hashable {
    let id: String
    static let components = Self(id: "components")
    static let features = Self(id: "features")
}

enum MenuBarPanelLayout {
    static let editingButtonHeight: CGFloat = 28
    static let editingActionBarVerticalPadding: CGFloat = 8
    static let editingActionBarHeight = editingButtonHeight + editingActionBarVerticalPadding * 2
    static let tabIconSize: CGFloat = 12
    static let tabItemHeight: CGFloat = 24
    static let tabCapsuleInset: CGFloat = 2
    static let headerHeight = tabItemHeight + tabCapsuleInset * 2
    static let headerAccessoryWidth: CGFloat = 28
    static let headerAccessoryHeight: CGFloat = 28
    static let headerAccessorySpacing: CGFloat = 4
    static let cornerRadius: CGFloat = 12
    static let featureRowSpacing: CGFloat = 8
    static func rowHeight(for item: PluginPanelRowSnapshot) -> CGFloat { 44 }
    static let minimumContentHeight: CGFloat = 184
    static let contentVerticalPadding: CGFloat = 10
    static let contentTopPadding: CGFloat = 6
    static let contentBottomPadding: CGFloat = 4
    static let outerPadding: CGFloat = 6
    static let minimumPanelHeight: CGFloat = 200
    static let maximumPanelHeight: CGFloat = 600
    static let editingPanelChromeHeight = headerHeight + editingActionBarHeight + outerPadding * 2
    static func maximumContentHeight(for screen: NSScreen?) -> CGFloat { maximumPanelHeight - headerHeight }
    static func panelHeight(forContentHeight height: CGFloat) -> CGFloat { height + headerHeight }
}

@MainActor
private final class FixtureState: ObservableObject {
    @Published var editing = true
    @Published var selectedPanelID = "components"
    let editingFeedback = MenuBarPanelEditingFeedback()
}

private struct CrossPanelFixtureRoot: View {
    @ObservedObject var host: PluginHost
    @ObservedObject var state: FixtureState
    @ObservedObject var session: PanelLayoutEditingSession

    var body: some View {
        VStack(spacing: 4) {
            MenuBarPanelTabs(panels: host.menuBarPanels, selectedPanelID: state.selectedPanelID,
                onSelect: { _ in }, isEditing: true, itemDragSession: session,
                onItemDragHover: { id in
                    guard session.validateSource(in: host) else { return }
                    session.enterPanel(id, ids: host.panelEntries(in: id).map(\.id))
                    state.selectedPanelID = id
                })
                .frame(height: MenuBarPanelLayout.headerHeight)
            PanelLayoutEditor(pluginHost: host, panelID: state.selectedPanelID, onDismiss: {}, session: session)
                .id(state.selectedPanelID)
        }
        .padding(6)
        .frame(width: 316, height: 400)
    }
}

private struct FixtureRoot: View {
    @ObservedObject var host: PluginHost
    @ObservedObject var state: FixtureState
    let surface: FixtureSurface
    @ObservedObject var session: PanelLayoutEditingSession

    var body: some View {
        VStack(spacing: 4) {
            MenuBarPanelEditingControls(
                canUndoLayout: session.canUndo(in: host, panelID: surface.panelID),
                feedback: state.editingFeedback, onUndoLayout: undo, onDone: { state.editing = false }) {
                    MenuBarPanelTabs(
                        panels: MenuBarPanelDefinition.defaults,
                        selectedPanelID: surface == .dashboard ? "components" : "features",
                        onSelect: { _ in }, isEditing: state.editing)
                }
                .frame(height: MenuBarPanelLayout.headerHeight)

            if state.editing {
                VStack(spacing: 0) {
                    PanelLayoutEditor(
                        pluginHost: host,
                        panelID: surface.panelID,
                        onDismiss: {},
                        session: session
                    )

                    MenuBarPanelEditingActionBar()
                        .frame(height: MenuBarPanelLayout.editingActionBarHeight)
                }
            } else {
                Text("Finished")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(6)
        .frame(width: 316, height: 500)
    }

    private func undo() {
        session.undo(in: host, panelID: surface.panelID)
    }
}

@main
@MainActor
private struct PanelLayoutInteractionFixture {
    private static var originalPointer: CGPoint?

    @MainActor private static func positionPointer(at point: CGPoint, in window: NSWindow) {
        if originalPointer == nil { originalPointer = CGEvent(source: nil)?.location }
        let screenPoint = window.convertPoint(toScreen: point)
        CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: CGDisplayBounds(CGMainDisplayID()).height - screenPoint.y))
    }

    private static func restorePointer() {
        if let point = originalPointer { CGWarpMouseCursorPosition(point) }
        originalPointer = nil
    }
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if CommandLine.arguments[1] == "cross-panels" {
            runCrossPanelInteraction(application)
            return
        }
        if CommandLine.arguments[1] == "tabs" {
            runTabInteractions(application)
            return
        }
        let surface: FixtureSurface = CommandLine.arguments[1] == "features" ? .featurePanel : .dashboard
        let rtl = CommandLine.arguments[2] == "rtl"
        let host = PluginHost(compact: CommandLine.arguments[1] == "compact")
        let state = FixtureState()
        let session = PanelLayoutEditingSession()
        var previewOffsets: [Int?] = []
        let previewSubscription = session.dragPreview.$target.sink { previewOffsets.append($0?.offset) }
        defer { previewSubscription.cancel() }
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 360, height: 70),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let controller = NSHostingController(
            rootView: FixtureRoot(host: host, state: state, surface: surface, session: session)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight))
        popover.contentViewController = controller
        popover.show(
            relativeTo: CGRect(x: 160, y: 20, width: 20, height: 20), of: window.contentView!, preferredEdge: .maxY)
        application.activate(ignoringOtherApps: true)

        func source(_ id: String) -> PanelLayoutDragSourceView {
            guard
                let entry = host.panelEntries(in: surface.panelID).first(where: { $0.pluginID == id }),
                let view = descendants(controller.view).compactMap({ $0 as? PanelLayoutDragSourceView })
                    .first(where: { $0.identifier?.rawValue == "panel.layout.drag.\(entry.id)" })
            else {
                fail("Missing drag source \(id)")
            }
            return view
        }
        func requireOrder(_ ids: [String], feedback: PanelLayoutEditingSession.Feedback) {
            let actual = host.panelEntries(in: surface.panelID).map(\.pluginID)
            guard actual == ids, session.token == nil, session.feedback == feedback else {
                fail(
                    "Expected \(ids)/\(feedback), got \(actual)/\(session.feedback); active=\(session.token != nil), previews=\(previewOffsets)"
                )
            }
        }
        let dragWindow = controller.view.window!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let target = source("c")
            let end = target.convert(
                CGPoint(
                    x: rtl && surface == .dashboard ? 24 : target.bounds.width - 24,
                    y: surface == .dashboard ? target.bounds.midY : target.bounds.height - 4), to: nil)
            drag(source("a"), to: end, in: dragWindow) {
                requireOrder(["b", "c", "a"], feedback: .saved)
                let outsideCanvas = controller.view.convert(
                    CGPoint(x: 150, y: controller.view.bounds.height - 26), to: nil)
                drag(source("a"), to: outsideCanvas, in: dragWindow) {
                    requireOrder(["b", "c", "a"], feedback: .cancelled)
                    let first = source("b")
                    let start = first.convert(
                        CGPoint(x: rtl && surface == .dashboard ? first.bounds.width - 8 : 8, y: 8), to: nil)
                    drag(source("a"), to: start, in: dragWindow) {
                        requireOrder(["a", "b", "c"], feedback: .saved)
                        let root = controller.view
                        click(
                            root.convert(
                                CGPoint(x: rtl ? root.bounds.width - 28 : 28, y: 6 + MenuBarPanelLayout.headerHeight / 2),
                                to: nil
                            ),
                            in: dragWindow)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            requireOrder(["b", "c", "a"], feedback: .undone)
                            click(
                                root.convert(
                                    CGPoint(x: rtl ? 28 : root.bounds.width - 28, y: 6 + MenuBarPanelLayout.headerHeight / 2),
                                    to: nil
                                ),
                                in: dragWindow)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                guard !state.editing else { fail("Done did not finish editing") }
                                emit(
                                    "PASS \(CommandLine.arguments[1]) \(CommandLine.arguments[2]): native drops, cancellation, recovery, Undo, Done"
                                )
                                popover.close()
                                window.close()
                                exit(0)
                            }
                        }
                    }
                }
            }
        }
        let watchdog = Timer(timeInterval: 12, repeats: false) { _ in
            Task { @MainActor in
                fail("Native interaction timed out")
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        application.run()
    }

    @MainActor private static func runTabInteractions(_ application: NSApplication) {
        let navigation = MenuBarPanelTabNavigationView(frame: CGRect(x: 0, y: 0, width: 160, height: MenuBarPanelLayout.headerHeight))
        let strip = navigation.strip
        var panels = MenuBarPanelDefinition.defaults + [
            MenuBarPanelDefinition(id: "work", name: "Work", systemImage: "star"),
        ]
        var selectedID = "components"
        var moves = 0
        var iconChanges = 0
        strip.isEditing = true
        strip.update(panels: panels, selectedPanelID: selectedID)
        navigation.configure(theme: Theme(), contrast: .standard)
        strip.onMove = { id, offset in
            moves += 1
            let ids = PanelLayoutDestination.moving(id, toOffset: offset, in: panels.map(\.id))
            panels = ids.compactMap { id in panels.first { $0.id == id } }
            strip.update(panels: panels, selectedPanelID: selectedID)
        }
        strip.onSelect = { id in
            selectedID = id
            strip.update(panels: panels, selectedPanelID: id)
        }
        strip.onChangeIcon = { _ in iconChanges += 1 }
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 160, height: MenuBarPanelLayout.headerHeight),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = navigation
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        func tab(_ id: String) -> NSView {
            guard let view = descendants(strip).first(where: { $0.accessibilityIdentifier() == "menuBarPanel.tab.\(id)" })
            else { fail("Missing tab \(id)") }
            return view
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let last = tab("work")
            drag(tab("components"), to: last.convert(CGPoint(x: last.bounds.midX, y: 8), to: nil), in: window) {
                guard panels.map(\.id) == ["features", "work", "components"], moves == 1,
                      selectedID == "components", iconChanges == 0, strip.draggedID == nil else {
                    fail("Native tab drop did not commit exactly once or triggered activation")
                }
                drag(tab("components"), to: CGPoint(x: 60, y: -60), in: window) {
                    guard moves == 1, strip.draggedID == nil, strip.previewIDs == panels.map(\.id), iconChanges == 0 else {
                        fail("Cancelled tab drag changed the layout or opened the icon picker")
                    }
                    let other = tab("work")
                    let point = other.convert(CGPoint(x: other.bounds.midX, y: other.bounds.midY), to: nil)
                    click(point, in: window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        guard selectedID == "work", iconChanges == 0 else { fail("Click after a drag did not select the tab") }
                        click(point, in: window)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            guard iconChanges == 1 else { fail("Clicking the selected tab did not edit its icon") }
                            emit("PASS tabs: native drop, cancellation, selection, and selected-tab icon action")
                            window.close()
                            exit(0)
                        }
                    }
                }
            }
        }
        application.run()
    }

    @MainActor private static func runCrossPanelInteraction(_ application: NSApplication) {
        let host = PluginHost(pluginIDs: ["a"])
        host.configuration.panels.append(.init(id: "work", name: "Work", systemImage: "star"))
        let before = host.configuration
        let entry = host.panelEntries(in: "components")[0]
        let state = FixtureState()
        let session = PanelLayoutEditingSession()
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 360, height: 70),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        let controller = NSHostingController(rootView: CrossPanelFixtureRoot(host: host, state: state, session: session))
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        popover.show(relativeTo: CGRect(x: 160, y: 20, width: 20, height: 20), of: window.contentView!, preferredEdge: .maxY)
        application.activate(ignoringOtherApps: true)
        let dragWindow = controller.view.window!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let source = descendants(controller.view).compactMap({ $0 as? PanelLayoutDragSourceView }).first,
                  let tab = descendants(controller.view).first(where: { $0.accessibilityIdentifier() == "menuBarPanel.tab.work" })
            else { fail("Missing cross-panel controls") }
            let start = source.convert(CGPoint(x: 12, y: 8), to: nil)
            let target = tab.convert(CGPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
            positionPointer(at: start, in: dragWindow)
            post(.leftMouseDown, at: start, in: dragWindow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                positionPointer(at: CGPoint(x: start.x + 8, y: start.y), in: dragWindow)
                post(.leftMouseDragged, at: CGPoint(x: start.x + 8, y: start.y), in: dragWindow)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                positionPointer(at: target, in: dragWindow)
                post(.leftMouseDragged, at: target, in: dragWindow)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard state.selectedPanelID == "work", session.token != nil else {
                    fail("Hover did not switch: selected=\(state.selectedPanelID), active=\(session.token != nil), native=\(session.nativeDragSource.isDragging)")
                }
                guard host.configuration == before, source.window == nil,
                      let canvas = descendants(controller.view).first(where: { $0.identifier?.rawValue == "panel.layout.canvas" })
                else { fail("Hover changed preferences or failed to replace the source view") }
                let drop = canvas.convert(CGPoint(x: 30, y: 100), to: nil)
                positionPointer(at: drop, in: dragWindow)
                post(.leftMouseDragged, at: drop, in: dragWindow)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { post(.leftMouseUp, at: drop, in: dragWindow) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard host.panelEntries(in: "work") == [entry], session.token == nil,
                          session.feedback == .saved, session.canUndo(in: host, panelID: "work")
                    else { fail("Cross-panel drop failed: \(host.panelEntries(in: "work")), feedback=\(session.feedback)") }
                    session.undo(in: host, panelID: "work")
                    guard host.configuration == before else { fail("Cross-panel Undo did not restore the layout") }
                    emit("PASS cross-panels: native hover switch, source view replacement, empty-panel drop, and Undo")
                    popover.close()
                    window.close()
                    restorePointer()
                    exit(0)
                }
            }
        }
        application.run()
    }

    @MainActor private static func drag(
        _ source: NSView, to end: CGPoint,
        in window: NSWindow, completion: @escaping @MainActor () -> Void
    ) {
        let start = source.convert(CGPoint(x: source.bounds.midX, y: 8), to: nil)
        let steps: [(NSEvent.EventType, CGPoint)] = [
            (.leftMouseDown, start),
            (.leftMouseDragged, CGPoint(x: start.x + 8, y: start.y)), (.leftMouseDragged, end), (.leftMouseUp, end),
        ]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(index + 1)) {
                positionPointer(at: step.1, in: window)
                post(step.0, at: step.1, in: window)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            restorePointer()
            completion()
        }
    }

    @MainActor private static func click(_ point: CGPoint, in window: NSWindow) {
        post(.leftMouseDown, at: point, in: window)
        post(.leftMouseUp, at: point, in: window)
    }

    @MainActor private static func post(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        // Events are scoped to the synthetic popover, with no global input injection.
        NSApp.postEvent(event, atStart: false)
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func emit(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func fail(_ message: String) -> Never {
        restorePointer()
        emit("FAIL: " + message)
        exit(1)
    }
}

// Editing confirmations use the same window accessor contract as the host app.
struct MenuWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    init(_ onWindow: @escaping (NSWindow?) -> Void) { self.onWindow = onWindow }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { onWindow(view.window) }
}
enum MenuBarPanelWindowRegistry {
    static func markEditingPopover(_ window: NSWindow) {}
}
