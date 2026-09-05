import AppKit
import MacToolsPluginKit
import XCTest

@MainActor
final class PluginPresentationSafetyTests: XCTestCase {
    func testPreparationEndsEditingInOtherWindows() throws {
        let editorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let orderingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        editorWindow.contentView = NSView(frame: editorWindow.contentLayoutRect)
        editorWindow.contentView?.addSubview(textField)

        XCTAssertTrue(editorWindow.makeFirstResponder(textField))
        XCTAssertTrue(editorWindow.firstResponder is NSTextView)

        PluginPresentationSafety.prepareForWindowOrdering(
            orderingWindow,
            windows: [editorWindow, orderingWindow]
        )

        XCTAssertFalse(editorWindow.firstResponder is NSTextView)
    }

    func testPreparationPreservesEditingInWindowBeingOrdered() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(textField)

        XCTAssertTrue(window.makeFirstResponder(textField))
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)

        PluginPresentationSafety.prepareForWindowOrdering(window, windows: [window])

        XCTAssertTrue(window.firstResponder === fieldEditor)
    }

    func testPreparationCanRestoreEditingAfterOrderingNonactivatingPanel() throws {
        let editorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        editorWindow.contentView = NSView(frame: editorWindow.contentLayoutRect)
        editorWindow.contentView?.addSubview(textField)

        XCTAssertTrue(editorWindow.makeFirstResponder(textField))
        XCTAssertTrue(editorWindow.firstResponder is NSTextView)

        let restoration = PluginPresentationSafety.prepareForWindowOrdering(
            panel,
            windows: [editorWindow, panel],
            restoringTextEditingIn: editorWindow
        )

        XCTAssertFalse(editorWindow.firstResponder is NSTextView)
        restoration?.restore()
        XCTAssertTrue(editorWindow.firstResponder is NSTextView)
    }

    func testPreparationRestoresStandaloneTextViewInsteadOfItsDelegate() throws {
        let editorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 100))
        let delegate = StandaloneTextViewDelegate()
        textView.delegate = delegate
        editorWindow.contentView = NSView(frame: editorWindow.contentLayoutRect)
        editorWindow.contentView?.addSubview(textView)

        XCTAssertTrue(editorWindow.makeFirstResponder(textView))
        XCTAssertTrue(editorWindow.firstResponder === textView)

        let restoration = PluginPresentationSafety.prepareForWindowOrdering(
            panel,
            windows: [editorWindow, panel],
            restoringTextEditingIn: editorWindow
        )
        XCTAssertFalse(editorWindow.firstResponder === textView)
        XCTAssertFalse(editorWindow.firstResponder === delegate)

        restoration?.restore()

        XCTAssertTrue(editorWindow.firstResponder === textView)
        XCTAssertFalse(editorWindow.firstResponder === delegate)
    }

    func testEveryWindowPresentationCallsiteUsesTheSharedSafetyBoundary() throws {
        let violations = try sourceFiles().flatMap { url -> [String] in
            let source = try String(contentsOf: url, encoding: .utf8)
            let patterns = [
                #"\.(?:makeKeyAndOrderFront|orderFrontRegardless|orderFront)\("#,
                #"(?m)^\s*(?:makeKeyAndOrderFront|orderFrontRegardless)\("#,
                #"\.(?:runModal|beginSheetModal)\("#,
                #"\.show\(\s*relativeTo:"#,
            ]
            return try patterns.flatMap { pattern -> [String] in
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(source.startIndex..., in: source)
                return regex.matches(in: source, range: range).compactMap { match in
                    guard let swiftRange = Range(match.range, in: source) else { return nil }
                    let callOffset = source.distance(from: source.startIndex, to: swiftRange.lowerBound)
                    let contextStartOffset = max(0, callOffset - 240)
                    let contextStart = source.index(source.startIndex, offsetBy: contextStartOffset)
                    let context = source[contextStart ..< swiftRange.lowerBound]
                    guard context.contains("PluginPresentationSafety.prepareForWindowOrdering") else {
                        let line = source[..<swiftRange.lowerBound].split(separator: "\n").count
                        return "\(url.path):\(line)"
                    }
                    return nil
                }
            }
        }

        XCTAssertEqual(violations, [], "Unprotected AppKit window presentation calls: \(violations)")
    }

    func testEveryStatusItemCreationUsesTheSharedSafetyBoundary() throws {
        let violations = try sourceFiles().flatMap { url -> [String] in
            let source = try String(contentsOf: url, encoding: .utf8)
            let pattern = #"NSStatusBar\.system\.statusItem\("#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            return regex.matches(in: source, range: range).compactMap { match in
                guard let swiftRange = Range(match.range, in: source) else { return nil }
                let callOffset = source.distance(from: source.startIndex, to: swiftRange.lowerBound)
                let contextStartOffset = max(0, callOffset - 240)
                let contextStart = source.index(source.startIndex, offsetBy: contextStartOffset)
                let context = source[contextStart ..< swiftRange.lowerBound]
                guard context.contains("PluginPresentationSafety.prepareForWindowOrdering") else {
                    let line = source[..<swiftRange.lowerBound].split(separator: "\n").count
                    return "\(url.path):\(line)"
                }
                return nil
            }
        }

        XCTAssertEqual(violations, [], "Unprotected status-item creation calls: \(violations)")
    }

    func testEveryStatusItemRemovalUsesTheSharedSafetyBoundary() throws {
        let violations = try sourceFiles().flatMap { url -> [String] in
            let source = try String(contentsOf: url, encoding: .utf8)
            let pattern = #"NSStatusBar\.system\.removeStatusItem\("#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            return regex.matches(in: source, range: range).compactMap { match in
                guard let swiftRange = Range(match.range, in: source) else { return nil }
                let callOffset = source.distance(from: source.startIndex, to: swiftRange.lowerBound)
                let contextStartOffset = max(0, callOffset - 240)
                let contextStart = source.index(source.startIndex, offsetBy: contextStartOffset)
                let context = source[contextStart ..< swiftRange.lowerBound]
                guard context.contains("PluginPresentationSafety.prepareForWindowOrdering") else {
                    let line = source[..<swiftRange.lowerBound].split(separator: "\n").count
                    return "\(url.path):\(line)"
                }
                return nil
            }
        }

        XCTAssertEqual(violations, [], "Unprotected status-item removal calls: \(violations)")
    }

    func testFragileInputCallbacksDoNotPassSessionObjectsDirectlyToC() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Plugins/TrackpadGestures/Sources/MultitouchDeviceSession.swift",
            "Plugins/MouseEnhancer/Sources/MouseEnhancerSession.swift",
            "Plugins/MouseEnhancer/Sources/MouseEnhancerMiddleClickSession.swift",
        ]
        let violations = try relativePaths.compactMap { relativePath -> String? in
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            return source.contains("Unmanaged.passUnretained(self).toOpaque()")
                ? relativePath
                : nil
        }

        XCTAssertEqual(violations, [], "Direct unretained C callback owners: \(violations)")
    }

    private func sourceFiles() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return ["Sources", "Plugins"].flatMap { directory in
            let base = root.appendingPathComponent(directory, isDirectory: true)
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                return [URL]()
            }
            return enumerator.compactMap { element in
                guard let url = element as? URL,
                      url.pathExtension == "swift",
                      (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else {
                    return nil
                }
                return url
            }
        }
    }
}

private final class StandaloneTextViewDelegate: NSViewController, NSTextViewDelegate {}

final class PluginCallbackContextTests: XCTestCase {
    private final class Owner {
        private let onDeinit: () -> Void

        init(onDeinit: @escaping () -> Void = {}) {
            self.onDeinit = onDeinit
        }

        deinit {
            onDeinit()
        }
    }

    func testInvalidationPreventsNewCallbackDelivery() {
        let owner = Owner()
        let context = PluginCallbackContext(owner: owner)
        var deliveryCount = 0

        context.withOwner { _ in deliveryCount += 1 }
        context.invalidate()
        context.withOwner { _ in deliveryCount += 1 }

        XCTAssertEqual(deliveryCount, 1)
    }

    func testAdmittedCallbackRetainsOwnerUntilDeliveryCompletes() throws {
        var didDeinitialize = false
        var owner: Owner? = Owner { didDeinitialize = true }
        let context = PluginCallbackContext(owner: try XCTUnwrap(owner))

        context.withOwner { _ in
            owner = nil
            XCTAssertFalse(didDeinitialize)
        }

        XCTAssertTrue(didDeinitialize)
    }
}
