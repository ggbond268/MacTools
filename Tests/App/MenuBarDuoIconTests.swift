import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MenuBarDuoIconTests: XCTestCase {
    func testDefaultArtworkIsTemplateAtStandardSize() throws {
        let image = MenuBarDuoIcon.image(for: connectedSnapshot)
        XCTAssertEqual(image.size, NSSize(width: 24, height: 24))
        XCTAssertTrue(image.isTemplate)
        let pixels = try alphaPixels(image)
        XCTAssertTrue(pixels.contains { $0 > 0 })
        XCTAssertEqual(pixels[0], 0)
        XCTAssertEqual(pixels[47], 0)
    }

    func testBatteryWiFiAndNetworkChangeIndependently() throws {
        let baseline = try alphaPixels(MenuBarDuoIcon.image(for: connectedSnapshot))
        var battery = connectedSnapshot
        battery.battery = .level(fraction: 0.1, isCharging: false)
        let batteryPixels = try alphaPixels(MenuBarDuoIcon.image(for: battery))
        XCTAssertNotEqual(baseline, batteryPixels)
        XCTAssertEqual(region(baseline, x: 15..<33, y: 18..<34), region(batteryPixels, x: 15..<33, y: 18..<34))

        var wifi = connectedSnapshot
        wifi.wifi = .connected(level: 1)
        let wifiPixels = try alphaPixels(MenuBarDuoIcon.image(for: wifi))
        XCTAssertNotEqual(baseline, wifiPixels)
        XCTAssertEqual(region(baseline, x: 0..<48, y: 15..<48), region(wifiPixels, x: 0..<48, y: 15..<48))

        var network = connectedSnapshot
        network.network = .disconnected
        network.connectionKind = nil
        let networkPixels = try alphaPixels(MenuBarDuoIcon.image(for: network))
        XCTAssertNotEqual(baseline, networkPixels)
        XCTAssertEqual(region(baseline, x: 0..<48, y: 0..<15), region(networkPixels, x: 0..<48, y: 0..<15))
    }

    func testChargingAndMissingBatteryHaveDistinctArtwork() throws {
        var charging = connectedSnapshot
        charging.battery = .level(fraction: 0.8, isCharging: true)
        var missing = connectedSnapshot
        missing.battery = .notPresent
        var empty = connectedSnapshot
        empty.battery = .level(fraction: 0, isCharging: false)
        XCTAssertNotEqual(try alphaPixels(MenuBarDuoIcon.image(for: charging)), try alphaPixels(MenuBarDuoIcon.image(for: connectedSnapshot)))
        XCTAssertNotEqual(try alphaPixels(MenuBarDuoIcon.image(for: missing)), try alphaPixels(MenuBarDuoIcon.image(for: empty)))
    }

    func testEthernetAndOtherRoutesDoNotRenderAsWiFi() throws {
        var ethernet = connectedSnapshot
        ethernet.connectionKind = .ethernet
        var other = connectedSnapshot
        other.connectionKind = .other
        let wifi = try alphaPixels(MenuBarDuoIcon.image(for: connectedSnapshot))
        XCTAssertNotEqual(wifi, try alphaPixels(MenuBarDuoIcon.image(for: ethernet)))
        XCTAssertNotEqual(wifi, try alphaPixels(MenuBarDuoIcon.image(for: other)))
    }

    func testExternalPowerShowsPlugWhenChargingIsPausedOrComplete() throws {
        for fraction in [0.8, 1.0] {
            var unplugged = connectedSnapshot
            unplugged.battery = .level(fraction: fraction, isCharging: false)
            var pluggedIn = unplugged
            pluggedIn.battery = .level(fraction: fraction, isCharging: false, isExternalPowerConnected: true)
            var charging = pluggedIn
            charging.battery = .level(fraction: fraction, isCharging: true, isExternalPowerConnected: true)

            let unpluggedPixels = try alphaPixels(MenuBarDuoIcon.image(for: unplugged))
            let pluggedInPixels = try alphaPixels(MenuBarDuoIcon.image(for: pluggedIn))
            let chargingPixels = try alphaPixels(MenuBarDuoIcon.image(for: charging))
            XCTAssertNotEqual(unpluggedPixels, pluggedInPixels)
            XCTAssertNotEqual(pluggedInPixels, chargingPixels)
            XCTAssertEqual(region(unpluggedPixels, x: 0..<48, y: 0..<31), region(pluggedInPixels, x: 0..<48, y: 0..<31))
            XCTAssertNotEqual(MenuBarSystemStatusDescription.text(for: pluggedIn), MenuBarSystemStatusDescription.text(for: unplugged))
            XCTAssertNotEqual(MenuBarSystemStatusDescription.text(for: pluggedIn), MenuBarSystemStatusDescription.text(for: charging))
        }
    }

    func testPowerIndicatorsFitInsideArtworkBounds() throws {
        for charging in [false, true] {
            var snapshot = connectedSnapshot
            snapshot.battery = .level(fraction: 0.8, isCharging: charging, isExternalPowerConnected: true)
            let image = MenuBarDuoIcon.image(for: snapshot)
            // Resolve subpixel padding before checking that neither indicator reaches the image edge.
            let pixels = try rgbaPixels(image, scale: 4)
            let side = 96
            for offset in 0..<side {
                XCTAssertEqual(pixels[offset].alpha, 0)
                XCTAssertEqual(pixels[(side - 1) * side + offset].alpha, 0)
                XCTAssertEqual(pixels[offset * side].alpha, 0)
                XCTAssertEqual(pixels[offset * side + side - 1].alpha, 0)
            }
        }
    }

    func testRingUsesChargingGreenBeforeLowBatteryRedAndStopsRedAtTwentyPercent() throws {
        for (fraction, charging) in [(0.8, true), (0.1, true), (0.199, false), (0, false)] {
            var snapshot = connectedSnapshot
            snapshot.battery = .level(fraction: fraction, isCharging: charging)
            let image = MenuBarDuoIcon.image(for: snapshot)
            let pixels = try rgbaPixels(image)
            XCTAssertFalse(image.isTemplate)
            XCTAssertEqual(pixels.contains(where: \.isGreen), charging)
            XCTAssertEqual(pixels.contains(where: \.isRed), !charging)
        }
        for fraction in [0.2, 0.8, 1] {
            var snapshot = connectedSnapshot
            snapshot.battery = .level(fraction: fraction, isCharging: false, isExternalPowerConnected: true)
            let image = MenuBarDuoIcon.image(for: snapshot)
            XCTAssertTrue(image.isTemplate)
            XCTAssertFalse(try rgbaPixels(image).contains { $0.isRed || $0.isGreen })
        }
    }

    func testColoredRingPreservesBlackAndWhiteSymbolsInEachAppearance() throws {
        var snapshot = connectedSnapshot
        snapshot.battery = .level(fraction: 0.7, isCharging: true)
        let light = MenuBarDuoIcon.image(for: snapshot, appearance: .light)
        let dark = MenuBarDuoIcon.image(for: snapshot, appearance: .dark)
        let lightPixels = try rgbaPixels(light)
        let darkPixels = try rgbaPixels(dark)

        XCTAssertFalse(light.isTemplate)
        XCTAssertFalse(dark.isTemplate)
        XCTAssertTrue(lightPixels.contains(where: \.isGreen))
        XCTAssertTrue(darkPixels.contains(where: \.isGreen))
        XCTAssertTrue(lightPixels.contains { $0.alpha > 200 && max($0.red, $0.green, $0.blue) < 10 })
        XCTAssertTrue(darkPixels.contains { min($0.red, $0.green, $0.blue, $0.alpha) > 200 })
    }

    private var connectedSnapshot: MenuBarSystemStatusSnapshot {
        MenuBarSystemStatusSnapshot(
            battery: .level(fraction: 0.8, isCharging: false),
            wifi: .connected(level: 4), network: .connected, connectionKind: .wifi
        )
    }

    private func alphaPixels(_ image: NSImage) throws -> [UInt8] {
        try rgbaPixels(image).map(\.alpha)
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        var isGreen: Bool { alpha > 15 && Int(green) > Int(red) + 20 && Int(green) > Int(blue) + 20 }
        var isRed: Bool { alpha > 15 && Int(red) > Int(green) + 20 && Int(red) > Int(blue) + 20 }
    }

    private func rgbaPixels(_ image: NSImage, scale: CGFloat = 2) throws -> [Pixel] {
        let side = Int(image.size.width * scale)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(side * side)).map {
            Pixel(red: data[$0 * 4], green: data[$0 * 4 + 1], blue: data[$0 * 4 + 2], alpha: data[$0 * 4 + 3])
        }
    }

    private func region(_ pixels: [UInt8], x: Range<Int>, y: Range<Int>) -> [UInt8] {
        // Bitmap rows start at the top; artwork coordinates start at the bottom.
        y.flatMap { row in x.map { column in pixels[(47 - row) * 48 + column] } }
    }
}
