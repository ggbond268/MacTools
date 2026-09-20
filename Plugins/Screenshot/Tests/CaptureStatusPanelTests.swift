import AppKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class CaptureStatusPanelTests: XCTestCase {
    func testRecordingAndScrollingUseConfirmationButtonAppearance() throws {
        for hasCancel in [false, true] {
            let panel = CaptureStatusPanel(primaryTitle: "Finish", cancelTitle: hasCancel ? "Cancel" : nil,
                                           indicatorColor: hasCancel ? nil : .systemRed)
            defer { panel.orderOut(nil) }
            let bar = try XCTUnwrap(panel.contentView)
            let buttons = descendants(of: bar).compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, hasCancel ? 2 : 1)
            for button in buttons {
                let reference = NSButton(title: button.title, target: nil, action: nil)
                CaptureActionBar.configure(reference, isPrimary: button.title == "Finish")
                XCTAssertEqual(button.bezelStyle, reference.bezelStyle)
                XCTAssertEqual(button.controlSize, reference.controlSize)
                XCTAssertEqual(button.font, reference.font)
                XCTAssertTrue(button.isBordered)
                if #available(macOS 26, *) {
                    XCTAssertEqual(button.borderShape, reference.borderShape)
                }
            }
            if #available(macOS 26, *) {
                let glass = try XCTUnwrap(bar as? NSGlassEffectView)
                XCTAssertEqual(glass.style, .regular)
                XCTAssertEqual(glass.cornerRadius, bar.fittingSize.height / 2, accuracy: 0.5)
            } else {
                let glass = try XCTUnwrap(bar as? NSVisualEffectView)
                XCTAssertEqual(glass.material, .popover)
                XCTAssertEqual(glass.blendingMode, .behindWindow)
            }
        }
    }

    func testStatusUpdatesPreserveConfirmationPaddingAndHeight() throws {
        let panel = CaptureStatusPanel(primaryTitle: "Finish", cancelTitle: "Cancel")
        defer { panel.orderOut(nil) }
        let bar = try XCTUnwrap(panel.contentView)
        let initialHeight = panel.frame.height
        let stack = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSStackView }.first)
        XCTAssertEqual(stack.spacing, 8)
        XCTAssertEqual(stack.alignment, .centerY)
        for text in ["Scroll downward · 1.0 screens", "Finishing…", "00:01"] {
            panel.update(text)
            bar.layoutSubtreeIfNeeded()
            let first = try XCTUnwrap(stack.arrangedSubviews.first)
            let last = try XCTUnwrap(stack.arrangedSubviews.last)
            // AppKit text fields extend their frame beyond the Auto Layout alignment rect.
            let firstAlignment = try XCTUnwrap(first.superview).convert(first.alignmentRect(forFrame: first.frame), to: bar)
            XCTAssertEqual(firstAlignment.minX, CaptureActionBar.insets.left, accuracy: 0.5)
            XCTAssertEqual(bar.bounds.maxX - last.convert(last.bounds, to: bar).maxX, CaptureActionBar.insets.right, accuracy: 0.5)
            for button in stack.arrangedSubviews.compactMap({ $0 as? NSButton }) {
                let frame = button.convert(button.bounds, to: bar)
                XCTAssertEqual(frame.minY, CaptureActionBar.insets.bottom, accuracy: 0.5)
                XCTAssertEqual(bar.bounds.maxY - frame.maxY, CaptureActionBar.insets.top, accuracy: 0.5)
            }
            XCTAssertEqual(panel.frame.height, initialHeight, accuracy: 0.5)
        }
    }

    func testButtonCallbacksAndDisabledPrimaryArePreserved() throws {
        let panel = CaptureStatusPanel(primaryTitle: "Finish", cancelTitle: "Cancel")
        defer { panel.orderOut(nil) }
        let buttons = descendants(of: try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }
        let primary = try XCTUnwrap(buttons.first { $0.title == "Finish" })
        let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })
        var finishes = 0, cancellations = 0
        panel.onPrimary = { finishes += 1 }
        panel.onCancel = { cancellations += 1 }
        primary.performClick(nil)
        cancel.performClick(nil)
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(cancellations, 1)
        panel.update("Finishing…", primaryEnabled: false)
        XCTAssertFalse(primary.isEnabled)
        XCTAssertTrue(cancel.isEnabled)
        panel.update("Retry")
        XCTAssertTrue(primary.isEnabled)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
