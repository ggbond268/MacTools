import AppKit
import CoreGraphics
import Foundation

enum WindowCoordinateSpace {
    static func anchorMaximumY(in screens: [NSScreen]) -> CGFloat? {
        (screens.first(where: { $0.frame.origin == .zero }) ?? screens.first)?.frame.maxY
    }

    static func accessibilityRect(_ rect: CGRect, anchorMaximumY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: anchorMaximumY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func appKitRect(_ rect: CGRect, anchorMaximumY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: anchorMaximumY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

@MainActor
protocol WindowScreenProviding {
    func currentScreens() -> [WindowScreen]
}

@MainActor
struct SystemWindowScreenProvider: WindowScreenProviding {
    func currentScreens() -> [WindowScreen] {
        let screens = NSScreen.screens
        guard let anchorMaximumY = WindowCoordinateSpace.anchorMaximumY(in: screens) else {
            return []
        }
        return screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            let directDisplayID = number?.uint32Value
            return WindowScreen(
                id: stableIdentifier(
                    directDisplayID: directDisplayID,
                    fallbackIndex: index,
                    name: screen.localizedName
                ),
                directDisplayID: directDisplayID,
                frame: WindowCoordinateSpace.accessibilityRect(
                    screen.frame,
                    anchorMaximumY: anchorMaximumY
                ),
                visibleFrame: WindowCoordinateSpace.accessibilityRect(
                    screen.visibleFrame,
                    anchorMaximumY: anchorMaximumY
                )
            )
        }
    }

    private func stableIdentifier(
        directDisplayID: CGDirectDisplayID?,
        fallbackIndex: Int,
        name: String
    ) -> String {
        guard let directDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(directDisplayID)?.takeRetainedValue()
        else {
            return "screen:\(fallbackIndex):\(name)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

}
