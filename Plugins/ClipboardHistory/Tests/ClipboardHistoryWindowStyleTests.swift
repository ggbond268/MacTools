import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryWindowStyleTests: XCTestCase {
    func testHistoryWindowMovesOnlyThroughItsExplicitDragHandle() {
        let panel = NSPanel()
        panel.isMovableByWindowBackground = true

        ClipboardHistoryPanelController.restrictMovementToExplicitDragRegions(panel)

        XCTAssertFalse(panel.isMovableByWindowBackground)
    }

    func testContentChangesCannotResizePanelOrOverrideItsMinimumSize() async {
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 900, height: 620),
            styleMask: ClipboardHistoryPanelController.panelStyleMask, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.minSize = NSSize(width: 860, height: 540)
        let hosting = ClipboardHistoryWindowContent.makeHostingView(rootView: sizingProbe(height: 40))
        panel.contentView = hosting
        XCTAssertTrue(hosting.hostingView.sizingOptions.isEmpty)
        for targetSize in [NSSize(width: 900, height: 620), NSSize(width: 1000, height: 700)] {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: targetSize), display: false)
            let expected = panel.frame
            for height in [1400.0, 80.0, 2200.0, 40.0] {
                hosting.hostingView.rootView = sizingProbe(height: height)
                hosting.layoutSubtreeIfNeeded()
                await Task.yield()
                XCTAssertEqual(panel.frame, expected, "Content must not resize the window")
                XCTAssertEqual(panel.minSize, NSSize(width: 860, height: 540))
            }
        }
    }

    private func sizingProbe(height: CGFloat) -> some View {
        VStack {
            Text("Search")
            Text("Loading, results, or a tall preview").frame(height: height)
        }
    }

    func testSettingsDisclosureKeepsFullWidthHeaderAndDoesNotAddAnOuterCard() {
        let collapsed = NSHostingView(rootView: ClipboardSettingsDisclosure(isExpanded: .constant(false)) {
            Text("Advanced controls").frame(height: 180)
        } label: {
            Text("Shortcuts")
        }.frame(width: 400))
        let expanded = NSHostingView(rootView: ClipboardSettingsDisclosure(isExpanded: .constant(true)) {
            Text("Advanced controls").frame(height: 180)
        } label: {
            Text("Shortcuts")
        }.frame(width: 400))
        XCTAssertEqual(collapsed.fittingSize.width, 400, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(collapsed.fittingSize.height, 36)
        XCTAssertEqual(expanded.fittingSize.width, 400, accuracy: 0.5)
        XCTAssertGreaterThan(expanded.fittingSize.height, collapsed.fittingSize.height + 180)
    }

    func testAdvancedDividerIsCompactTransparentAndHasATrailingHairline() throws {
        for scheme in [ColorScheme.light, .dark] {
            for title in ["Advanced", "高级", "Erweitert", "Расширенные настройки", "متقدم"] {
                let view = ClipboardSettingsAdvancedDivider(title: title)
                    .frame(width: 400)
                    .environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: view)
                XCTAssertEqual(hosting.fittingSize.width, 400, accuracy: 0.5)
                XCTAssertLessThan(hosting.fittingSize.height, 45, "The divider must not become another large card")

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)).alphaComponent, 0)
                let lineRows = (0..<bitmap.pixelsHigh).filter { y in
                    (bitmap.colorAt(x: bitmap.pixelsWide - 2, y: y)?.alphaComponent ?? 0) > 0
                }
                XCTAssertFalse(lineRows.isEmpty, "The trailing horizontal rule must be visible")
                XCTAssertLessThanOrEqual(lineRows.count, 2, "The rule must remain a hairline")
                XCTAssertGreaterThan(try XCTUnwrap(lineRows.first), bitmap.pixelsHigh / 2,
                    "More breathing room belongs above the divider than below it")
            }
        }
    }

    func testHistoryContentFillsNativeWindowFrameBeforeAndAfterResizing() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 620),
            styleMask: ClipboardHistoryPanelController.panelStyleMask,
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        let probe = NSView()
        let hostingView = ClipboardHistoryWindowContent.makeHostingView(
            rootView: WindowContentProbe(view: probe)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        panel.contentView = hostingView
        XCTAssertTrue(hostingView.hostingView.safeAreaRegions.isEmpty)

        let screen = try XCTUnwrap(NSScreen.main)
        for frame in [panel.frame, screen.visibleFrame, NSRect(x: 140, y: 180, width: 860, height: 540)] {
            panel.setFrame(frame, display: false)
            hostingView.layoutSubtreeIfNeeded()
            let contentFrame = probe.convert(probe.bounds, to: nil)
            XCTAssertEqual(contentFrame.minY, 0, accuracy: 0.5)
            XCTAssertEqual(contentFrame.maxY, panel.frame.height, accuracy: 0.5)
            XCTAssertEqual(contentFrame.width, panel.frame.width, accuracy: 0.5)

            let origin = ClipboardHistoryActionPalettePlacement.origin(
                parentFrame: panel.frame,
                paletteSize: NSSize(width: 430, height: 520),
                visibleFrame: screen.visibleFrame
            )
            if panel.frame.maxY <= screen.visibleFrame.maxY && panel.frame.minY >= screen.visibleFrame.minY {
                XCTAssertEqual(origin.y + 520, panel.frame.minY + contentFrame.maxY, accuracy: 0.5)
            }
        }
    }

    func testShortcutGuideKeepsLongBindingsOnOneLine() {
        for shortcut in ["↑↓ / ⌃P / ⌃N", "⌃Tab / ⇧⌃Tab", "⇧⌘Return", "Space", "Esc"] {
            let view = NSHostingView(rootView: ClipboardHistoryShortcutGuideRow(
                hint: .init(title: "Navigate", shortcut: shortcut)
            ).frame(width: 378))
            XCTAssertLessThan(view.fittingSize.height, 30)
            XCTAssertEqual(view.fittingSize.width, 378, accuracy: 0.5)
        }
    }

    func testCompanionWindowsShareTheSameSurfaceInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            for reducesTransparency in [false, true] {
                let history = try renderSurface(.history, scheme: scheme, reducesTransparency: reducesTransparency)
                let actions = try renderSurface(.actions, scheme: scheme, reducesTransparency: reducesTransparency)
                for point in [(60, 50), (20, 20), (100, 80)] {
                    let lhs = try XCTUnwrap(history.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
                    let rhs = try XCTUnwrap(actions.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
                    XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 0.005)
                    XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 0.005)
                    XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 0.005)
                    XCTAssertEqual(lhs.alphaComponent, rhs.alphaComponent, accuracy: 0.005)
                    if reducesTransparency {
                        XCTAssertEqual(lhs.alphaComponent, 1, accuracy: 0.005)
                    }
                }
            }
        }
    }

    private func renderSurface(
        _ role: ClipboardHistoryWindowSurface.Role,
        scheme: ColorScheme,
        reducesTransparency: Bool
    ) throws -> NSBitmapImageRep {
        let appearance = try XCTUnwrap(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: ClipboardHistoryWindowSurface(
                role: role, reducesTransparency: reducesTransparency
            )
                .frame(width: 120, height: 100)
                .environment(\.colorScheme, scheme))
            renderer.scale = 1
            image = renderer.cgImage
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }
}

private struct WindowContentProbe: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
