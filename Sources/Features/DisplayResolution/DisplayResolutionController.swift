import AppKit
import CoreGraphics
import Foundation

@MainActor
protocol DisplayResolutionControlling {
    func listConnectedDisplays() -> [DisplayInfo]
    func listAvailableResolutions(for displayID: CGDirectDisplayID) -> [DisplayResolutionInfo]
    func applyResolution(
        _ info: DisplayResolutionInfo,
        for displayID: CGDirectDisplayID
    ) -> Result<Void, DisplayResolutionError>
}

@MainActor
final class DisplayResolutionController {
    func listConnectedDisplays() -> [DisplayInfo] {
        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeCount)

        let maxCount = max(activeCount, 16)
        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(maxCount))
        CGGetActiveDisplayList(maxCount, &displayIDs, &activeCount)

        return Array(displayIDs.prefix(Int(activeCount))).enumerated().compactMap { index, displayID in
            if CGDisplayIsInMirrorSet(displayID) != 0, CGDisplayIsMain(displayID) == 0 {
                return nil
            }

            let name = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            })?.localizedName ?? "Display \(index + 1)"

            return DisplayInfo(
                id: displayID,
                name: name,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                isMain: CGDisplayIsMain(displayID) != 0
            )
        }
    }

    func listAvailableResolutions(for displayID: CGDirectDisplayID) -> [DisplayResolutionInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let rawModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            AppLog.displayResolutionController.error("CGDisplayCopyAllDisplayModes returned nil for displayID \(displayID)")
            return []
        }

        let currentID = CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID ?? 0

        let candidates = rawModes.filter { mode in
            let flags = mode.ioFlags
            return mode.isUsableForDesktopGUI() && flags & DisplayModeFlags.safe != 0 && flags & DisplayModeFlags.notPreset == 0
        }

        let infos = candidates.map { mode in
            let flags = mode.ioFlags
            return DisplayResolutionInfo(
                modeId: mode.ioDisplayModeID,
                width: mode.width,
                height: mode.height,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                refreshRate: mode.refreshRate,
                isHiDPI: mode.pixelWidth > mode.width,
                isNative: flags & DisplayModeFlags.native != 0,
                isDefault: flags & DisplayModeFlags.default != 0,
                isCurrent: mode.ioDisplayModeID == currentID
            )
        }
        return Self.sortModes(Self.deduplicateModes(infos))
    }

    nonisolated static func deduplicateModes(_ modes: [DisplayResolutionInfo]) -> [DisplayResolutionInfo] {
        var bestByKey: [String: DisplayResolutionInfo] = [:]

        for mode in modes {
            let key = deduplicationKey(for: mode)

            if let existing = bestByKey[key] {
                bestByKey[key] = preferredMode(existing: existing, candidate: mode)
            } else {
                bestByKey[key] = mode
            }
        }

        return Array(bestByKey.values)
    }

    nonisolated static func sortModes(_ modes: [DisplayResolutionInfo]) -> [DisplayResolutionInfo] {
        modes.sorted {
            if $0.width != $1.width {
                return $0.width > $1.width
            }

            if $0.height != $1.height {
                return $0.height > $1.height
            }

            if $0.isCurrent != $1.isCurrent {
                return $0.isCurrent
            }

            if $0.isHiDPI != $1.isHiDPI {
                return $0.isHiDPI
            }

            return $0.refreshRate > $1.refreshRate
        }
    }

    @discardableResult
    func applyResolution(
        _ info: DisplayResolutionInfo,
        for displayID: CGDirectDisplayID
    ) -> Result<Void, DisplayResolutionError> {
        guard let target = fetchCGDisplayMode(modeId: info.modeId, displayID: displayID) else {
            return .failure(.modeNotFound(modeId: info.modeId))
        }

        var config: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&config)
        guard beginError == .success, let config else {
            return .failure(.beginConfigFailed(beginError))
        }

        let configureError = CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        guard configureError == .success else {
            CGCancelDisplayConfiguration(config)
            return .failure(.configureFailed(configureError))
        }

        let completeError = CGCompleteDisplayConfiguration(config, .permanently)
        guard completeError == .success else {
            return .failure(.completeFailed(completeError))
        }

        return .success(())
    }

    private func fetchCGDisplayMode(modeId: Int32, displayID: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }
        return modes.first(where: { $0.ioDisplayModeID == modeId })
    }

    nonisolated private static func deduplicationKey(for mode: DisplayResolutionInfo) -> String {
        "\(mode.width)x\(mode.height)"
    }

    nonisolated private static func preferredMode(
        existing: DisplayResolutionInfo,
        candidate: DisplayResolutionInfo
    ) -> DisplayResolutionInfo {
        if existing.isCurrent != candidate.isCurrent {
            return existing.isCurrent ? existing : candidate
        }

        if existing.isHiDPI != candidate.isHiDPI {
            return existing.isHiDPI ? existing : candidate
        }

        return existing.refreshRate >= candidate.refreshRate ? existing : candidate
    }
}

extension DisplayResolutionController: DisplayResolutionControlling {}
