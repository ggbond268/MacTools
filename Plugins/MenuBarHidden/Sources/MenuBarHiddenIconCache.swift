// SPDX-License-Identifier: GPL-3.0-only
// Copyright (Ice) © 2023–2025 Jordan Baird
// Copyright (Thaw) © 2026 Toni Förster
// Licensed under the GNU GPLv3.
// Adapted from Thaw / Ice; see Sources/Resources/ThirdPartyNotices/manifest.json.
// Restored and adapted for MacTools on 2026-09-07.

import AppKit
import Combine
import CoreGraphics
import Darwin

// MARK: - MenuBarHiddenIconCache
//
// Captures live menu-bar item screenshots via the same SkyLight window capture
// path used by Thaw. ScreenCaptureKit does not reliably capture menu-bar item
// windows once the hidden divider has pushed them off the visible display.
// Screen Recording permission is mandatory; without it there are no icons to
// show (this plugin gates its UI on the permission check).
//
// Cache layout: keyed by `MenuBarItemTag`, with window-ID-insensitive lookup
// for refreshed items. Cache size is bounded so scrolling through many apps
// does not grow memory without limit.

@MainActor
final class MenuBarHiddenIconCache: ObservableObject {
    struct CapturedImage {
        let cgImage: CGImage
        let scale: CGFloat

        var scaledSize: CGSize {
            CGSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
        }

        var nsImage: NSImage {
            NSImage(cgImage: cgImage, size: scaledSize)
        }

        static func isVisuallyEqual(_ old: CapturedImage?, _ new: CapturedImage?) -> Bool {
            guard let old, let new else { return old == nil && new == nil }
            if old.cgImage === new.cgImage { return true }
            guard old.scale == new.scale,
                  old.cgImage.width == new.cgImage.width,
                  old.cgImage.height == new.cgImage.height
            else {
                return false
            }
            guard let oldData = old.cgImage.dataProvider?.data,
                  let newData = new.cgImage.dataProvider?.data
            else {
                return false
            }
            return oldData == newData
        }
    }

    @Published private(set) var images: [MenuBarItemTag: CapturedImage] = [:]
    var onLayoutMetricsChange: (() -> Void)?

    private static let maxCacheSize = 200
    private var captureTask: Task<Void, Never>?
    private var pendingRefresh: (groups: [[MenuBarItem]], displayID: CGDirectDisplayID)?
    private var recentlyFailed = [MenuBarItemTag: Date]()
    private let failureCooldown: TimeInterval = 2

    /// Refresh icons for the given section groups. Requests are coalesced
    /// instead of cancelling in-flight captures so rapid divider frame updates
    /// cannot starve the cache and leave the layout bar blank.
    func refresh(groups: [[MenuBarItem]], displayID: CGDirectDisplayID) {
        pendingRefresh = (groups.filter { !$0.isEmpty }, displayID)
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            await self?.drainRefreshRequests()
        }
    }

    func image(for tag: MenuBarItemTag) -> CapturedImage? {
        if let image = images[tag] {
            return image
        }
        return images.first { $0.key.matchesIgnoringWindowID(tag) }?.value
    }

    func purgeMissing(keepingKeys validKeys: Set<String>) {
        images = images.filter { validKeys.contains($0.key.stableKey) }
    }

    // MARK: - Private

    private func drainRefreshRequests() async {
        while let request = pendingRefresh {
            pendingRefresh = nil
            await captureAll(groups: request.groups, displayID: request.displayID)
        }
        captureTask = nil
    }

    private func captureAll(groups: [[MenuBarItem]], displayID: CGDirectDisplayID) async {
        let items = groups.flatMap { $0 }
        guard !items.isEmpty else { return }

        var next = images
        let validTags = Set(items.map(\.tag))
        let scale = Self.backingScaleFactor(for: displayID)

        var capturedImages = [MenuBarItemTag: CapturedImage]()
        for group in groups {
            guard !Task.isCancelled else { return }
            capturedImages.merge(refreshImages(of: group, scale: scale)) { _, new in new }
        }

        next = next.filter { cachedTag, _ in
            validTags.contains { $0.matchesIgnoringWindowID(cachedTag) }
        }

        var didChangeLayoutMetrics = false

        for (tag, image) in capturedImages {
            for oldTag in next.keys where oldTag != tag && oldTag.matchesIgnoringWindowID(tag) {
                next.removeValue(forKey: oldTag)
            }
            if !CapturedImage.isVisuallyEqual(next[tag], image) {
                if next[tag]?.scaledSize != image.scaledSize {
                    didChangeLayoutMetrics = true
                }
                next[tag] = image
            }
        }

        if next.count > Self.maxCacheSize {
            let validTags = Set(items.map(\.tag))
            let tagsToRemove = next.keys
                .filter { tag in !validTags.contains { $0.matchesIgnoringWindowID(tag) } }
                .prefix(next.count - Self.maxCacheSize)
            for tag in tagsToRemove {
                next.removeValue(forKey: tag)
            }
        }

        MenuBarHiddenLog.plugin.debug(
            "Menu bar icon cache updated: displayID=\(displayID), scale=\(Double(scale)), items=\(items.count), captured=\(capturedImages.count), icons=\(next.count)"
        )
        images = next
        if didChangeLayoutMetrics {
            onLayoutMetricsChange?()
        }
    }

    private static func backingScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private func refreshImages(of items: [MenuBarItem], scale: CGFloat) -> [MenuBarItemTag: CapturedImage] {
        let capturableItems = items.filter { !shouldSkipCapture(for: $0) }
        guard !capturableItems.isEmpty else { return [:] }

        var windowIDs = [CGWindowID]()
        var storage = [CGWindowID: (MenuBarItem, CGRect)]()
        var boundsUnion = CGRect.null

        for item in capturableItems {
            guard let bounds = Self.validBounds(MenuBarHiddenCaptureWindowServer.screenRect(for: item.windowID) ?? item.bounds)
            else {
                continue
            }
            windowIDs.append(item.windowID)
            storage[item.windowID] = (item, bounds)
            boundsUnion = boundsUnion.union(bounds)
        }

        guard !windowIDs.isEmpty, !boundsUnion.isNull, !boundsUnion.isEmpty else {
            MenuBarHiddenLog.plugin.debug("refreshImages: no items with bounds, skipping")
            return [:]
        }

        guard let compositeImage = MenuBarHiddenSkyLight.captureWindowsImage(
            windowIDs: windowIDs,
            options: [.boundsIgnoreFraming, .bestResolution]
        ) else {
            MenuBarHiddenLog.plugin.debug("SkyLight menu-bar icon capture failed for \(windowIDs.count) windows")
            return captureIndividualImages(of: capturableItems, scale: scale)
        }

        let expectedWidth = boundsUnion.width * scale
        guard CGFloat(compositeImage.width) == expectedWidth else {
            MenuBarHiddenLog.plugin.debug(
                "refreshImages: width mismatch (expected \(expectedWidth), got \(compositeImage.width)), skipping"
            )
            return captureIndividualImages(of: capturableItems, scale: scale)
        }

        guard !Self.isFullyTransparent(compositeImage) else {
            MenuBarHiddenLog.plugin.debug("refreshImages: composite is transparent, skipping")
            return captureIndividualImages(of: capturableItems, scale: scale)
        }

        var newImages = [MenuBarItemTag: CapturedImage]()
        var cropNilCount = 0

        for windowID in windowIDs {
            guard let (item, bounds) = storage[windowID] else { continue }

            let cropRect = CGRect(
                x: (bounds.origin.x - boundsUnion.origin.x) * scale,
                y: (bounds.origin.y - boundsUnion.origin.y) * scale,
                width: bounds.width * scale,
                height: bounds.height * scale
            )

            guard let image = compositeImage.cropping(to: cropRect) else {
                cropNilCount += 1
                recordCaptureFailure(for: item)
                continue
            }
            recordCaptureSuccess(for: item)
            newImages[item.tag] = CapturedImage(cgImage: image, scale: scale)
        }

        MenuBarHiddenLog.plugin.debug(
            "refreshImages: captured \(newImages.count)/\(windowIDs.count) items, cropNil=\(cropNilCount)"
        )
        return newImages
    }

    private func captureIndividualImages(of items: [MenuBarItem], scale: CGFloat) -> [MenuBarItemTag: CapturedImage] {
        var images = [MenuBarItemTag: CapturedImage]()
        var nilCount = 0
        var transparentCount = 0

        for item in items where !shouldSkipCapture(for: item) {
            guard let image = MenuBarHiddenSkyLight.captureWindowsImage(
                windowIDs: [item.windowID],
                options: [.boundsIgnoreFraming, .bestResolution]
            ) else {
                nilCount += 1
                recordCaptureFailure(for: item)
                continue
            }

            guard !Self.isFullyTransparent(image) else {
                transparentCount += 1
                recordCaptureFailure(for: item)
                continue
            }

            recordCaptureSuccess(for: item)
            images[item.tag] = CapturedImage(cgImage: image, scale: scale)
        }

        MenuBarHiddenLog.plugin.debug(
            "individual refreshImages: captured \(images.count)/\(items.count), nil=\(nilCount), transparent=\(transparentCount)"
        )
        return images
    }

    private func shouldSkipCapture(for item: MenuBarItem) -> Bool {
        guard let lastFailedAt = recentlyFailed[item.tag] else { return false }
        if Date().timeIntervalSince(lastFailedAt) < failureCooldown {
            return true
        }
        recentlyFailed.removeValue(forKey: item.tag)
        return false
    }

    private func recordCaptureFailure(for item: MenuBarItem) {
        recentlyFailed[item.tag] = Date()
    }

    private func recordCaptureSuccess(for item: MenuBarItem) {
        recentlyFailed.removeValue(forKey: item.tag)
    }

    private static func validBounds(_ bounds: CGRect?) -> CGRect? {
        guard
            let bounds,
            !bounds.isNull,
            !bounds.isEmpty,
            bounds.minX.isFinite,
            bounds.maxX.isFinite,
            bounds.minY.isFinite,
            bounds.maxY.isFinite
        else {
            return nil
        }
        return bounds
    }

    private static func isFullyTransparent(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0 else { return true }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel == 4 else { return isFullyTransparentSlow(image) }

        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        case .premultipliedFirst, .first, .premultipliedLast, .last, .alphaOnly:
            break
        @unknown default:
            return isFullyTransparentSlow(image)
        }

        let byteOrder = CGBitmapInfo(rawValue: image.bitmapInfo.rawValue).intersection(.byteOrderMask)
        let isLittleEndian: Bool
        switch byteOrder {
        case .byteOrder32Little:
            isLittleEndian = true
        case .byteOrder32Big:
            isLittleEndian = false
        default:
            return isFullyTransparentSlow(image)
        }

        let alphaOffset: Int
        switch (image.alphaInfo, isLittleEndian) {
        case (.premultipliedFirst, true), (.first, true):
            alphaOffset = 3
        case (.premultipliedLast, true), (.last, true):
            alphaOffset = 0
        case (.premultipliedFirst, false), (.first, false):
            alphaOffset = 0
        case (.premultipliedLast, false), (.last, false):
            alphaOffset = 3
        default:
            return isFullyTransparentSlow(image)
        }

        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return isFullyTransparentSlow(image)
        }

        let dataLength = CFDataGetLength(data)
        let requiredLength = (image.height - 1) * image.bytesPerRow
            + (image.width - 1) * bytesPerPixel
            + alphaOffset
            + 1
        guard dataLength >= requiredLength else { return isFullyTransparentSlow(image) }

        return withExtendedLifetime(data) {
            for row in 0 ..< image.height {
                let rowStart = row * image.bytesPerRow
                for column in 0 ..< image.width {
                    if bytes[rowStart + column * bytesPerPixel + alphaOffset] > 0 {
                        return false
                    }
                }
            }
            return true
        }
    }

    private static func isFullyTransparentSlow(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return true }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 }
    }
}

private enum MenuBarHiddenCaptureWindowServer {
    static func screenRect(for windowID: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        let result = menuBarHiddenCaptureCGSGetScreenRectForWindow(
            menuBarHiddenCaptureCGSDefaultConnectionForThread(),
            windowID,
            &rect
        )
        guard result == .success else { return nil }
        return rect
    }
}

private typealias MenuBarHiddenCaptureCGSConnectionID = Int32

@_silgen_name("CGSDefaultConnectionForThread")
private func menuBarHiddenCaptureCGSDefaultConnectionForThread() -> MenuBarHiddenCaptureCGSConnectionID

@_silgen_name("CGSGetScreenRectForWindow")
private func menuBarHiddenCaptureCGSGetScreenRectForWindow(
    _ cid: MenuBarHiddenCaptureCGSConnectionID,
    _ wid: CGWindowID,
    _ outRect: inout CGRect
) -> CGError

private enum MenuBarHiddenSkyLight {
    private typealias SLWindowListCreateImageFromArray = @convention(c) (
        CGRect,
        CFArray,
        CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    }()

    private static let captureFunction: SLWindowListCreateImageFromArray? = {
        guard let handle, let symbol = dlsym(handle, "SLWindowListCreateImageFromArray") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SLWindowListCreateImageFromArray.self)
    }()

    static func captureWindowsImage(
        windowIDs: [CGWindowID],
        options: CGWindowImageOption
    ) -> CGImage? {
        guard let captureFunction, let windowArray = cgWindowArray(with: windowIDs) else {
            return nil
        }
        return captureFunction(.null, windowArray, options)?.takeRetainedValue()
    }

    private static func cgWindowArray(with windowIDs: [CGWindowID]) -> CFArray? {
        var pointers: [UnsafeRawPointer?] = windowIDs.compactMap {
            UnsafeRawPointer(bitPattern: UInt($0))
        }
        guard !pointers.isEmpty else { return nil }

        var callbacks = CFArrayCallBacks(
            version: 0,
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil
        )
        return CFArrayCreate(nil, &pointers, pointers.count, &callbacks)
    }
}
