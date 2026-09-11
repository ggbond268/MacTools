// Synthetic interfaces keep native interaction acceptance independent of installed
// plugins and user data. The runner appends the unmodified production UI sources.
import AppKit
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
        let tabSelection = Color.gray
    }
    struct Texts {
        let primary = Color.black
        let secondary = Color.gray
    }
    struct Status { let warning = Color.orange }
    let surfaces = Surfaces()
    let text = Texts()
    let accent = Color.blue
    let status = Status()
}
struct ThemeKey: EnvironmentKey { static let defaultValue = Theme() }
extension EnvironmentValues {
    var menuBarPanelTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
enum PluginSystemImage { static func resolvedName(_ s: String) -> String { s } }
enum AppL10n {
    static func settings(_ s: String, defaultValue: String) -> String { defaultValue }
    static func settingsFormat(_ s: String, defaultValue: String, _ args: CVarArg...) -> String {
        String(format: defaultValue, arguments: args)
    }
}
enum PluginDisplaySurface { case dashboard, featurePanel }
struct PluginComponentSpan: Equatable {
    let width: Int
    let height: Int
}
struct PluginComponentItem: Identifiable {
    let id: String
    var title: String { id }
    let iconName = "circle"
    let iconTint = Color.blue
    let span: PluginComponentSpan
}
struct ComponentGridPlacement: Identifiable, Equatable {
    let id: String
    let row: Int
    let column: Int
    let span: PluginComponentSpan
    let yOffset: CGFloat
}
enum ComponentPanelLayout {
    static let columns = 4
    static let gridWidth: CGFloat = 304
    static let verticalSpacing: CGFloat = 6
    static func itemWidth(for span: PluginComponentSpan) -> CGFloat { CGFloat(span.width) * 78 - 8 }
    static func itemHeight(for span: PluginComponentSpan) -> CGFloat { CGFloat(span.height) * 8 }
    static func xOffset(for p: ComponentGridPlacement) -> CGFloat { CGFloat(p.column) * 78 }
    static func gridContentHeight(for ps: [ComponentGridPlacement]) -> CGFloat {
        ps.map { $0.yOffset + itemHeight(for: $0.span) }.max() ?? 164
    }
}
@MainActor final class PluginHost: ObservableObject {
    @Published var componentItems = [
        PluginComponentItem(id: "a", span: .init(width: 2, height: 12)),
        PluginComponentItem(id: "b", span: .init(width: 1, height: 24)),
        PluginComponentItem(id: "c", span: .init(width: 4, height: 12)),
    ]
    var panelItems: [PluginComponentItem] { componentItems }
    struct ViewItem { let content: AnyView }
    func componentViewItem(for id: String, dismiss: @escaping () -> Void) -> ViewItem {
        ViewItem(
            content: AnyView(
                Text(id).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.blue.opacity(0.15))))
    }
    func moveRenderedPlugin(id: String, toOffset: Int, on: PluginDisplaySurface) {
        let ids = PanelLayoutDestination.moving(id, toOffset: toOffset, in: componentItems.map(\.id))
        componentItems = ids.compactMap { i in componentItems.first { $0.id == i } }
    }
}
enum MenuBarPanelTab: CaseIterable {
    case components, features
    var systemImage: String { self == .components ? "square.grid.2x2" : "list.bullet" }
    var accessibilityTitle: String { String(describing: self) }
}

enum MenuBarPanelLayout {
    static let minimumContentHeight: CGFloat = 184
    static let contentVerticalPadding: CGFloat = 10
}

@MainActor
private final class FixtureState: ObservableObject {
    @Published var editing = true
}

private struct FixtureRoot: View {
    @ObservedObject var host: PluginHost
    @ObservedObject var state: FixtureState
    let surface: PluginDisplaySurface
    let session: PanelLayoutEditingSession

    var body: some View {
        VStack(spacing: 4) {
            MenuBarPanelToolbar(
                selectedTab: surface == .dashboard ? .components : .features,
                availableUpdateVersion: nil, canEditLayout: true, isEditingLayout: state.editing,
                onEditLayout: { state.editing.toggle() }, onTabSelection: { _ in },
                onOpenUpdate: {}, onOpenSettings: {}, onQuit: {}
            )
            .frame(height: 30)
            if state.editing {
                PanelLayoutEditor(pluginHost: host, surface: surface, onDismiss: {}, session: session)
            } else {
                Text("Finished")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(6)
        .frame(width: 316, height: 500)
    }
}

@main
private struct PanelLayoutInteractionFixture {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let surface: PluginDisplaySurface = CommandLine.arguments[1] == "dashboard" ? .dashboard : .featurePanel
        let rtl = CommandLine.arguments[2] == "rtl"
        let host = PluginHost()
        let state = FixtureState()
        let session = PanelLayoutEditingSession()
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
                let view = descendants(controller.view).compactMap({ $0 as? PanelLayoutDragSourceView })
                    .first(where: { $0.identifier?.rawValue == "panel.layout.drag.\(id)" })
            else {
                fail("Missing drag source \(id)")
            }
            return view
        }
        func requireOrder(_ ids: [String], feedback: PanelLayoutEditingSession.Feedback) {
            guard host.componentItems.map(\.id) == ids, session.token == nil, session.feedback == feedback else {
                fail(
                    "Expected \(ids)/\(feedback), got \(host.componentItems.map(\.id))/\(session.feedback); active=\(session.token != nil)"
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
                            root.convert(CGPoint(x: rtl ? 30 : 280, y: root.bounds.height - 26), to: nil),
                            in: dragWindow)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            requireOrder(["b", "c", "a"], feedback: .undone)
                            click(
                                root.convert(CGPoint(x: rtl ? root.bounds.width - 24 : 24, y: 20), to: nil),
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

    @MainActor private static func drag(
        _ source: PanelLayoutDragSourceView, to end: CGPoint,
        in window: NSWindow, completion: @escaping @MainActor () -> Void
    ) {
        let start = source.convert(CGPoint(x: source.bounds.midX, y: 8), to: nil)
        let steps: [(NSEvent.EventType, CGPoint)] = [
            (.leftMouseDown, start),
            (.leftMouseDragged, CGPoint(x: start.x + 8, y: start.y)), (.leftMouseDragged, end), (.leftMouseUp, end),
        ]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(index + 1)) {
                post(step.0, at: step.1, in: window)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: completion)
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
        emit("FAIL: " + message)
        exit(1)
    }
}
