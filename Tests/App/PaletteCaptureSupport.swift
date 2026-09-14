import AppKit
import ScreenCaptureKit
import SwiftUI
import XCTest

/// Opt-in review evidence from production panels with test stores. Rectangle
/// captures include any occluding windows; keep the synthetic review display clear.
@MainActor
final class PaletteCaptureSupport {
    let directory: URL
    private let backdrop: NSWindow
    private var captureIndex = 0
    private var records: [[String: Any]] = []

    init(name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MACTOOLS_PALETTE_CAPTURE_DIR"] else {
            throw XCTSkip("Opt-in native review capture; set TEST_RUNNER_MACTOOLS_PALETTE_CAPTURE_DIR")
        }
        directory = URL(fileURLWithPath: path).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screen = try XCTUnwrap(NSScreen.main)
        backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .floating
        setBackdrop(dark: false)
        backdrop.orderFront(nil)
    }

    func setBackdrop(dark: Bool) {
        backdrop.contentView = NSHostingView(rootView: ZStack {
            LinearGradient(colors: dark ? [.black, .indigo, .black] : [.yellow, .cyan, .pink],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 22) {
                ForEach(0..<18, id: \.self) { row in
                    Text(String(repeating: "SYNTHETIC BACKDROP  \(row)   ", count: 8))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(dark ? .white.opacity(0.35) : .black.opacity(0.25))
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    func capture(_ panel: NSWindow, label: String) async throws {
        if label != "second-display" { positionOnReviewScreen(panel) }
        if let screen = panel.screen { backdrop.setFrame(screen.frame, display: true) }
        backdrop.order(.below, relativeTo: panel.windowNumber)
        try await Task.sleep(for: .milliseconds(350))
        panel.contentView?.layoutSubtreeIfNeeded()
        let image: CGImage
        let method: String
        let name = String(format: "%02d-%@.png", captureIndex, label)
        let output = directory.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["MACTOOLS_PALETTE_EXTERNAL_CAPTURE"] == "1" {
            let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
            var request: [String: Any] = ["windowID": panel.windowNumber, "output": output.path,
                "rect": [Int(panel.frame.minX), Int(screenTop - panel.frame.maxY),
                         Int(panel.frame.width), Int(panel.frame.height)]]
            if let content = panel.contentView, let handle = findDragHandle(in: content) {
                let rect = panel.convertToScreen(handle.convert(handle.bounds, to: nil))
                request["dragPoint"] = [rect.midX, screenTop - rect.midY]
            }
            try JSONSerialization.data(withJSONObject: request).write(
                to: directory.appendingPathComponent("capture-request.json"), options: .atomic)
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: output.path) {
                try await Task.sleep(for: .milliseconds(100))
            }
            let data = try Data(contentsOf: output)
            image = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
            method = "screencapture panel rectangle above an owned synthetic backdrop"
        } else if CGPreflightScreenCaptureAccess() {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let window = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(panel.windowNumber) })
            let config = SCStreamConfiguration()
            config.width = Int(panel.frame.width * panel.backingScaleFactor)
            config.height = Int(panel.frame.height * panel.backingScaleFactor)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            method = "ScreenCaptureKit window capture"
        } else {
            let view = try XCTUnwrap(panel.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            image = try XCTUnwrap(bitmap.cgImage)
            method = "NSView cacheDisplay; WindowServer glass is not fully represented"
        }
        captureIndex += 1
        let bitmap = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output)
        records.append(["file": name, "method": method, "width": image.width, "height": image.height])
    }

    func exercise(_ panel: NSWindow, reopen: () -> Void) async throws {
        panel.appearance = NSAppearance(named: .aqua)
        try await capture(panel, label: "light-busy-background")
        setBackdrop(dark: true)
        panel.appearance = NSAppearance(named: .darkAqua)
        try await capture(panel, label: "dark-busy-background")
        panel.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        try await capture(panel, label: "high-contrast-dark")
        panel.appearance = NSAppearance(named: .aqua)
        let field = try XCTUnwrap(findField(in: try XCTUnwrap(panel.contentView)))
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("synthetic", replacementRange: NSRange(location: NSNotFound, length: 0))
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await capture(panel, label: "search")
        sendKey(panel, code: 125, characters: "\u{f701}")
        try await capture(panel, label: "keyboard-selection")
        let originalFrame = panel.frame
        let start = CACurrentMediaTime()
        for index in 0..<60 {
            panel.setFrameOrigin(NSPoint(x: originalFrame.minX + CGFloat(index % 20),
                                         y: originalFrame.minY + CGFloat(index % 15)))
            panel.displayIfNeeded()
            await Task.yield()
        }
        records.append(["operation": "60 programmatic moves (not physical dragging)",
                        "seconds": CACurrentMediaTime() - start])
        if panel.styleMask.contains(.resizable) {
            panel.setContentSize(NSSize(width: 1000, height: 700))
        }
        try await capture(panel, label: "moved-resized")
        sendKey(panel, code: 53, characters: "\u{1b}")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(panel.isVisible, "Escape should dismiss the production panel")
        reopen()
        try await capture(panel, label: "reopened")
        try await Task.sleep(for: .seconds(2))
        let cpuStart = Self.cpuTime()
        try await Task.sleep(for: .seconds(1))
        records.append(["operation": "idle process CPU over 1 second after 2-second settle",
                        "seconds": Self.cpuTime() - cpuStart])
        var openingTimes: [Double] = []
        for _ in 0..<8 {
            sendKey(panel, code: 53, characters: "\u{1b}")
            let start = CACurrentMediaTime()
            reopen()
            await Task.yield()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            openingTimes.append(CACurrentMediaTime() - start)
            try await Task.sleep(for: .milliseconds(80))
        }
        records.append(["operation": "warm open dispatch and layout (8 samples)", "seconds": openingTimes])
        let searchField = try XCTUnwrap(findField(in: try XCTUnwrap(panel.contentView)))
        XCTAssertTrue(panel.makeFirstResponder(searchField))
        let searchEditor = try XCTUnwrap(searchField.currentEditor() as? NSTextView)
        let searchCPU = Self.cpuTime()
        for query in ["synthetic", "synthetic n", "", "synthetic"] {
            searchEditor.selectAll(nil)
            searchEditor.insertText(query, replacementRange: NSRange(location: NSNotFound, length: 0))
            searchField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification,
                                                                    object: searchField))
            try await Task.sleep(for: .milliseconds(250))
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        records.append(["operation": "four paced searches process CPU", "seconds": Self.cpuTime() - searchCPU])
        let scrollingCPU = Self.cpuTime()
        for _ in 0..<20 {
            sendKey(panel, code: 125, characters: "\u{f701}")
            try await Task.sleep(for: .milliseconds(30))
        }
        records.append(["operation": "20 paced Down keys and scrolling process CPU",
                        "seconds": Self.cpuTime() - scrollingCPU])
        if ProcessInfo.processInfo.environment["MACTOOLS_PALETTE_LIVE_SYSTEM_SETTINGS"] == "1" {
            panel.appearance = nil
            // Reopening follows production placement. Establish the fixture's
            // review position before checking that settings preserve that frame.
            positionOnReviewScreen(panel)
            let field = try XCTUnwrap(findField(in: try XCTUnwrap(panel.contentView)))
            let accents = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite", "multicolor"]
            let cases = ["system-light-glass-min", "system-light-glass-max",
                         "system-dark-glass-min", "system-dark-glass-max"]
                + accents.map { "system-dark-accent-\($0)" }
                + accents.map { "system-light-accent-\($0)" }
                + ["system-light-increase-contrast", "system-light-reduce-transparency",
                   "system-dark-increase-contrast", "system-dark-reduce-transparency", "system-restored"]
            for label in cases {
                let frame = panel.frame
                let query = field.stringValue
                try await capture(panel, label: label)
                XCTAssertTrue(panel.isVisible)
                XCTAssertEqual(field.stringValue, query)
                XCTAssertEqual(panel.frame, frame)
                records.append(["appearanceCase": label,
                    "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                    "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast])
            }
        }
        if let otherScreen = NSScreen.screens.first(where: { $0 !== panel.screen }) {
            panel.setFrameOrigin(NSPoint(x: otherScreen.visibleFrame.midX - panel.frame.width / 2,
                                         y: otherScreen.visibleFrame.midY - panel.frame.height / 2))
            try await capture(panel, label: "second-display")
        }
    }

    private static func cpuTime() -> Double {
        var value = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    private func positionOnReviewScreen(_ panel: NSWindow) {
        guard let screen = NSScreen.screens.last, panel.screen !== screen else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                     y: screen.visibleFrame.midY - panel.frame.height / 2))
    }

    func finish() throws {
        backdrop.close()
        let report: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "displayCount": NSScreen.screens.count,
            "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "systemAccent": NSColor.controlAccentColor.description,
            "records": records,
            "limitations": "App appearance overrides do not establish live settings acceptance. Any externally driven system cases are listed in appearanceCase records. Movement and resize are programmatic. No physical drag, Spaces, display disconnect, or older OS acceptance is implied."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("capture-report.json"))
    }

    private func sendKey(_ window: NSWindow, code: UInt16, characters: String) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code) else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.sendEvent(event)
    }

    private func findField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { self.findField(in: $0) }.first
    }

    private func findDragHandle(in view: NSView) -> NSView? {
        let name = String(reflecting: type(of: view))
        if name.contains("WindowDragHandleNSView") || name.contains("ClipboardWindowDragRegion.DragView") {
            return view
        }
        return view.subviews.lazy.compactMap { self.findDragHandle(in: $0) }.first
    }
}
