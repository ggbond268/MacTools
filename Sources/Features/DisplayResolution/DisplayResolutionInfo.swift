import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
}

struct DisplayResolutionInfo: Equatable {
    let modeId: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
    let isNative: Bool
    let isDefault: Bool
    let isCurrent: Bool

    var displayTitle: String { "\(width)×\(height)" }
    var aspectRatio: Double { Double(width) / Double(height) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modeId == rhs.modeId
    }
}

enum DisplayResolutionError: Error, LocalizedError {
    case displayUnavailable(displayID: CGDirectDisplayID)
    case modeNotFound(modeId: Int32)
    case beginConfigFailed(CGError)
    case configureFailed(CGError)
    case completeFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "显示器已断开连接"
        case .modeNotFound:
            return "分辨率模式已失效"
        case .beginConfigFailed:
            return "无法开始显示配置"
        case .configureFailed:
            return "配置显示模式失败"
        case .completeFailed:
            return "提交显示配置失败"
        }
    }
}
