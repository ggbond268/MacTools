import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import CalendarPlugin

@MainActor
final class CalendarEventPopoverTests: XCTestCase {
    func testBackgroundCoversArrowAndBodyInBothAppearances() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let theme = PluginComponentTheme.system(colorScheme: scheme, contrast: .standard)
            try await checkBackground(theme: theme, scheme: scheme, name: "Calendar-hover-\(scheme)")
        }
    }

    func testCustomThemeAlsoCoversArrowAndBody() async throws {
        let base = PluginComponentTheme.system(colorScheme: .dark, contrast: .standard)
        let theme = PluginComponentTheme(
            surfaces: .init(panel: Color(red: 0.08, green: 0.18, blue: 0.22),
                card: Color.white.opacity(0.15), nested: base.surfaces.nested,
                nestedMuted: base.surfaces.nestedMuted, chip: base.surfaces.chip,
                control: base.surfaces.control, controlHover: base.surfaces.controlHover,
                track: base.surfaces.track, backplate: base.surfaces.backplate),
            text: base.text, status: base.status, dataSeries: base.dataSeries, interaction: base.interaction
        )
        try await checkBackground(theme: theme, scheme: .dark, name: "Calendar-hover-custom")
    }

    func testHoverEndsAndEmptyDatesClosePopover() throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let coordinator = CalendarEventPopoverPresenter.Coordinator()
        let theme = PluginComponentTheme.system(colorScheme: .light, contrast: .standard)
        update(coordinator, source: fixture.source, theme: theme)
        XCTAssertTrue(try XCTUnwrap(coordinator.popover).isShown)
        update(coordinator, source: fixture.source, theme: theme, isPresented: false)
        XCTAssertNil(coordinator.popover)
        update(coordinator, source: fixture.source, theme: theme)
        XCTAssertTrue(try XCTUnwrap(coordinator.popover).isShown)
        update(coordinator, source: fixture.source, theme: theme, count: 0)
        XCTAssertNil(coordinator.popover)
        update(coordinator, source: NSView(), theme: theme)
        XCTAssertNil(coordinator.popover)
    }

    private func checkBackground(theme: PluginComponentTheme, scheme: ColorScheme, name: String) async throws {
        let fixture = makeFixture()
        let coordinator = CalendarEventPopoverPresenter.Coordinator()
        defer {
            coordinator.close()
            fixture.window.close()
        }
        update(coordinator, source: fixture.source, theme: theme)
        let popover = try XCTUnwrap(coordinator.popover)
        XCTAssertTrue(popover.hasFullSizeContent, "The native popover must extend the background into its arrow")
        let root = try XCTUnwrap(popover.contentViewController?.view)
        let appearance = try XCTUnwrap(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        root.appearance = appearance
        root.window?.appearance = appearance
        try await Task.sleep(for: .milliseconds(100))
        root.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(root.subviews.first)
        XCTAssertGreaterThan(root.safeAreaInsets.bottom, 0)
        XCTAssertGreaterThan(content.frame.height, 50, "The event content must retain its intrinsic height")
        XCTAssertEqual(content.frame.width, 230, accuracy: 0.5)
        XCTAssertEqual(content.frame, root.safeAreaLayoutGuide.frame, "Text must stay within the unclipped content area")
        let bitmap = try snapshot(root)
        let scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
        let x = bitmap.pixelsWide / 2
        let arrow = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - Int(5 * scale))?.usingColorSpace(.deviceRGB))
        let body = try XCTUnwrap(bitmap.colorAt(x: x, y: Int((root.safeAreaInsets.top + 3) * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(arrow.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(arrow.redComponent, body.redComponent, accuracy: 0.01)
        XCTAssertEqual(arrow.greenComponent, body.greenComponent, accuracy: 0.01)
        XCTAssertEqual(arrow.blueComponent, body.blueComponent, accuracy: 0.01)
        let chrome = try XCTUnwrap(root.window?.contentView?.superview)
        let renderedPopover = try snapshot(chrome)
        let attachment = XCTAttachment(data: try XCTUnwrap(renderedPopover.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let originalHeight = content.frame.height
        update(coordinator, source: fixture.source, theme: theme, count: 8)
        try await Task.sleep(for: .milliseconds(100))
        let expandedRoot = try XCTUnwrap(popover.contentViewController?.view)
        expandedRoot.layoutSubtreeIfNeeded()
        let expandedContent = try XCTUnwrap(expandedRoot.subviews.first)
        XCTAssertEqual(expandedContent.frame.width, 230, accuracy: 0.5)
        XCTAssertGreaterThan(expandedContent.frame.height, originalHeight)
        XCTAssertLessThanOrEqual(expandedContent.frame.height, 260)
    }

    private func makeFixture() -> (window: NSWindow, source: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 400, y: 300, width: 360, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = NSView(frame: NSRect(x: 160, y: 100, width: 36, height: 36))
        window.contentView?.addSubview(source)
        PluginPresentationSafety.prepareForWindowOrdering(window, windows: [window])
        window.orderFront(nil)
        return (window, source)
    }

    private func update(_ coordinator: CalendarEventPopoverPresenter.Coordinator, source: NSView,
                        theme: PluginComponentTheme, count: Int = 2, isPresented: Bool = true) {
        coordinator.update(title: "September 17, 2026", subtitle: "Thursday", events: (0..<count).map { index in
            CalendarEventSummary(id: "\(index)", title: "Event \(index + 1)", timeText: "10:00–11:00",
                startDate: Date(), endDate: Date().addingTimeInterval(3600), isAllDay: false, color: .accent)
        }, localization: PluginLocalization(bundle: .main), theme: theme, isPresented: isPresented, sourceView: source)
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}
