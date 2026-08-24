import AppKit
import CoreGraphics
import Foundation

@MainActor
protocol StageManagerSafeAreaProviding {
    func safeVisibleFrame(for screen: WindowScreen) -> CGRect
}

@MainActor
struct SystemStageManagerSafeAreaProvider: StageManagerSafeAreaProviding {
    private let stageManagerEnabled: () -> Bool
    private let windowInfo: () -> [[String: Any]]

    init(
        stageManagerEnabled: @escaping () -> Bool = {
            UserDefaults(suiteName: "com.apple.WindowManager")?
                .bool(forKey: "GloballyEnabled") ?? false
        },
        windowInfo: @escaping () -> [[String: Any]] = {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
        }
    ) {
        self.stageManagerEnabled = stageManagerEnabled
        self.windowInfo = windowInfo
    }

    func safeVisibleFrame(for screen: WindowScreen) -> CGRect {
        guard stageManagerEnabled() else { return screen.visibleFrame }
        let candidates = windowInfo().compactMap { item -> CGRect? in
            guard item[kCGWindowOwnerName as String] as? String == "Dock",
                  let rawBounds = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  bounds.height >= screen.frame.height * 0.5,
                  bounds.width >= 32,
                  bounds.width <= min(320, screen.frame.width * 0.3),
                  bounds.intersects(screen.frame)
            else {
                return nil
            }
            return bounds.intersection(screen.frame)
        }

        var result = screen.visibleFrame
        for strip in candidates {
            if strip.minX <= screen.frame.minX + 4, strip.maxX > result.minX {
                let newMinX = min(strip.maxX, result.maxX - 1)
                result = CGRect(x: newMinX, y: result.minY, width: result.maxX - newMinX, height: result.height)
            } else if strip.maxX >= screen.frame.maxX - 4, strip.minX < result.maxX {
                result.size.width = max(1, strip.minX - result.minX)
            }
        }
        return result
    }
}
