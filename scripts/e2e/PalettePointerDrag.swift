import AppKit
import CoreGraphics

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 5, let windowID = UInt32(arguments[1]),
      let x = Double(arguments[2]), let y = Double(arguments[3]),
      CGPreflightPostEventAccess() else { fail("Expected window ID, handle coordinates, test product root, and pointer access") }

func windowInfo() -> [String: Any] {
    guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
          let row = rows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }) else {
        fail("Synthetic test window disappeared")
    }
    return row
}

func windowFrame() -> CGRect {
    guard let bounds = windowInfo()[kCGWindowBounds as String] as? [String: Any],
          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { fail("Missing test window bounds") }
    return rect
}

guard let pid = windowInfo()[kCGWindowOwnerPID as String] as? Int32,
      let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleURL else {
    fail("Missing test app")
}
let productRoot = URL(fileURLWithPath: arguments[4]).resolvingSymlinksInPath().path + "/"
guard bundle.resolvingSymlinksInPath().path.hasPrefix(productRoot) else { fail("Window is not owned by this test build") }
let original = windowFrame()
let start = CGPoint(x: x, y: y)
guard original.contains(start) else { fail("Drag handle is outside the test window") }
let cursor = CGEvent(source: nil)?.location
app.activate(options: [])
Thread.sleep(forTimeInterval: 0.3)

func post(_ type: CGEventType, at point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                             mouseCursorPosition: point, mouseButton: .left) else { fail("Cannot create pointer event") }
    event.post(tap: .cghidEventTap)
}

post(.mouseMoved, at: start)
Thread.sleep(forTimeInterval: 0.08)
post(.leftMouseDown, at: start)
Thread.sleep(forTimeInterval: 0.1)
for step in 1...30 {
    post(.leftMouseDragged, at: CGPoint(x: x + 80 * Double(step) / 30, y: y + 35 * Double(step) / 30))
    Thread.sleep(forTimeInterval: 0.015)
}
post(.leftMouseUp, at: CGPoint(x: x + 80, y: y + 35))
Thread.sleep(forTimeInterval: 0.2)
if let cursor { CGWarpMouseCursorPosition(cursor) }
let moved = windowFrame()
let delta = CGPoint(x: moved.minX - original.minX, y: moved.minY - original.minY)
let passed = abs(delta.x) >= 10 || abs(delta.y) >= 10
let result: [String: Any] = [
    "method": "Injected pointer events through production native drag handle",
    "movedX": delta.x, "movedY": delta.y, "passed": passed,
    "rect": [Int(moved.minX), Int(moved.minY), Int(moved.width), Int(moved.height)]
]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
if !passed { exit(1) }
