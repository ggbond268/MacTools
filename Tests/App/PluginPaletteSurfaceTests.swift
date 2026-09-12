import AppKit
import SwiftUI
import XCTest
@testable import MacToolsPluginKit

@MainActor
final class PluginPaletteSurfaceTests: XCTestCase {
    func testSelectionForegroundKeepsNormalTextContrastAcrossAccentColors() throws {
        // Include yellow, mid-gray, and a broad RGB grid, rather than assuming
        // that the system's preferred selected text always has enough contrast.
        for red in stride(from: 0.0, through: 1.0, by: 0.1) {
            for green in stride(from: 0.0, through: 1.0, by: 0.1) {
                for blue in stride(from: 0.0, through: 1.0, by: 0.1) {
                    let background = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
                    let text = PluginPaletteColors.readableSelectionText(background: background, preferred: .white)
                    let rgb = try XCTUnwrap(text.usingColorSpace(.sRGB))
                    let components = [red, green, blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                    let luminance = zip(components, [0.2126, 0.7152, 0.0722]).map(*).reduce(0, +)
                    let ratio = rgb.redComponent < 0.5 ? (luminance + 0.05) / 0.05 : 1.05 / (luminance + 0.05)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "Insufficient contrast for \(background)")
                }
            }
        }
        let preferred = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        XCTAssertEqual(PluginPaletteColors.readableSelectionText(background: .white, preferred: preferred), preferred)
    }

    func testReduceTransparencyProducesOpaqueSemanticBackgroundInBothAppearances() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua,
                               .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var image: CGImage?
            var expectedImage: CGImage?
            appearance.performAsCurrentDrawingAppearance {
                let scheme: ColorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
                let renderer = ImageRenderer(content: PluginPaletteSurface(reducesTransparency: true)
                    .frame(width: 120, height: 100)
                    .environment(\.colorScheme, scheme))
                image = renderer.cgImage
                expectedImage = ImageRenderer(content: Color(nsColor: .windowBackgroundColor)
                    .frame(width: 120, height: 100).environment(\.colorScheme, scheme)).cgImage
            }
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(image))
            let actual = try XCTUnwrap(bitmap.colorAt(x: 60, y: 50)?.usingColorSpace(.sRGB))
            let expected = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(expectedImage))
                .colorAt(x: 60, y: 50)?.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.alphaComponent, 1, accuracy: 0.01)
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.02)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.02)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.02)
        }
    }

    func testLiveSurfaceChangesPreserveFieldEditorCompositionHitTestingAndWindowFrame() async throws {
        guard ProcessInfo.processInfo.environment["MACTOOLS_PALETTE_CAPTURE_DIR"] != nil else {
            throw XCTSkip("Run with the sequential native capture fixture; parallel UI tests compete for key focus")
        }
        let state = SurfaceProbeState()
        let host = NSHostingView(rootView: SurfaceProbe(state: state))
        host.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 480, height: 240),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(150))
        let field = try XCTUnwrap(findField(in: host))
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("synthetic composition", selectedRange: NSRange(location: 9, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        let frame = panel.frame
        for (scheme, contrast, reduce) in [
            (ColorScheme.dark, ColorSchemeContrast.standard, false),
            (.light, .increased, false), (.dark, .increased, true), (.light, .standard, false)
        ] {
            state.scheme = scheme
            state.reduceTransparency = reduce
            panel.appearance = NSAppearance(named: contrast == .increased
                ? (scheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                : (scheme == .dark ? .darkAqua : .aqua))
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(findField(in: host) === field)
            XCTAssertTrue(field.currentEditor() === editor)
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(editor.string, "synthetic composition")
            XCTAssertEqual(panel.frame, frame)
            let center = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: host)
            let hit = host.hitTest(center)
            XCTAssertNotNil(hit)
            // SwiftUI may return its event-routing host instead of the native
            // field; the background must never become the input target.
            XCTAssertFalse(hit is NSVisualEffectView)
            if #available(macOS 26.0, *) { XCTAssertFalse(hit is NSGlassEffectView) }
        }
        editor.unmarkText()
        panel.orderOut(nil)
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.makeFirstResponder(field))
        XCTAssertEqual(field.stringValue, "synthetic composition")
        XCTAssertTrue(findField(in: host) === field)
    }

    private func findField(in view: NSView) -> NSTextField? {
        if let field = view as? PluginPaletteSearchField.SearchTextField { return field }
        return view.subviews.lazy.compactMap { self.findField(in: $0) }.first
    }
}

@MainActor
private final class SurfaceProbeState: ObservableObject {
    @Published var scheme = ColorScheme.light
    @Published var reduceTransparency = false
    @Published var query = ""
}

private struct SurfaceProbe: View {
    @ObservedObject var state: SurfaceProbeState

    var body: some View {
        VStack {
            PluginPaletteSearchBar(text: $state.query, placeholder: "Search synthetic content",
                accessibilityLabel: "Search", accessibilityIdentifier: "surface-probe-search",
                clearAccessibilityLabel: "Clear", focusRequestID: 0, onCommand: { _ in })
            Spacer()
        }
        .padding(16)
        .background { PluginPaletteSurface(reducesTransparency: state.reduceTransparency) }
        .environment(\.colorScheme, state.scheme)
    }
}
