import AppKit
import XCTest
@testable import DuoStatusPlugin

@MainActor
final class DuoStatusIconTests: XCTestCase {
    // MARK: Size

    func testIconSizeScalesTheArtworkAroundTheSameCenter() throws {
        // The small step is the shipping scale, so untouched settings keep today's icon.
        XCTAssertEqual(DuoStatusIconSize.small.artworkScale, 0.8)
        XCTAssertEqual(DuoStatusIconOptions.default.iconSize, .small)

        var widths: [CGFloat] = []
        for size in [DuoStatusIconSize.small, .medium, .large] {
            let bitmap = try rasterize(icon(snapshot(), options(\.iconSize, size)))
            let ink = try XCTUnwrap(inkBounds(bitmap), "Size \(size) drew nothing")
            widths.append(ink.width)
            // The artwork stays optically centered at every step.
            XCTAssertEqual(ink.midX, CGFloat(bitmap.pixelsWide) / 2, accuracy: 1.5, "Size \(size)")
            XCTAssertEqual(ink.midY, CGFloat(bitmap.pixelsHigh) / 2, accuracy: 1.5, "Size \(size)")
        }
        XCTAssertEqual(widths, widths.sorted(), "Larger steps must not shrink the artwork")
        XCTAssertGreaterThan(try XCTUnwrap(widths.last), try XCTUnwrap(widths.first))
    }

    // MARK: Battery colors

    /// `DuoStatusIconMappingsTests` owns the ladder itself; this covers how the
    /// renderer turns a role into a ring color and into the template flag.
    func testBatteryRoleDecidesTheRingColorAndTemplateRendering() throws {
        let discharging = snapshot(battery: .level(fraction: 0.6, isCharging: false))
        XCTAssertTrue(icon(discharging).isTemplate, "A plain battery keeps a tintable template image")

        let charging = icon(snapshot(battery: .level(fraction: 0.6, isCharging: true)))
        XCTAssertFalse(charging.isTemplate)
        let green = try strongestChroma(charging)
        XCTAssertGreaterThan(green.greenComponent, green.redComponent)

        let critical = icon(snapshot(battery: .level(fraction: 0.08, isCharging: true)))
        let red = try strongestChroma(critical)
        XCTAssertGreaterThan(red.redComponent, red.greenComponent, "Critical outranks charging")

        var uncolored = DuoStatusIconOptions.default
        uncolored.usesBatteryStatusColors = false
        XCTAssertTrue(icon(snapshot(battery: .level(fraction: 0.08, isCharging: true)), uncolored).isTemplate)
    }

    // MARK: Top gap

    /// `DuoStatusIconMappingsTests` owns the truth table; this covers that the
    /// renderer draws a distinct notch for every content it can be handed.
    func testTopGapDrawsEachContentDistinctly() throws {
        var percentage = options(\.showsBatteryPercentage, true)
        percentage.showsPercentageWhenConnected = true
        let level = 0.85
        let renders = [
            // Empty: on battery power with no number requested.
            try png(icon(snapshot(battery: .level(fraction: level, isCharging: false)))),
            // Bolt.
            try png(icon(snapshot(battery: .level(fraction: level, isCharging: true)))),
            // Plug.
            try png(icon(snapshot(battery: .level(
                fraction: level, isCharging: false, isExternalPowerConnected: true
            )))),
            // Percentage.
            try png(icon(snapshot(battery: .level(fraction: level, isCharging: false)), percentage))
        ]
        XCTAssertEqual(Set(renders).count, renders.count, "Each gap content needs its own artwork")
    }

    func testPercentageKeepsThreeDigitsInsideTheCanvas() throws {
        var full = options(\.showsBatteryPercentage, true)
        full.iconSize = .large
        let bitmap = try rasterize(icon(snapshot(battery: .level(fraction: 1, isCharging: false)), full))
        let ink = try XCTUnwrap(inkBounds(bitmap))
        XCTAssertGreaterThan(ink.minX, 0, "The largest artwork must not clip at the canvas edge")
        XCTAssertGreaterThan(ink.minY, 0)
        XCTAssertLessThan(ink.maxX, CGFloat(bitmap.pixelsWide))
        XCTAssertLessThan(ink.maxY, CGFloat(bitmap.pixelsHigh))

        // The ring's groove is drawn in full whatever the charge is, so the only
        // ink three digits add over one is the numerals themselves.
        let single = try rasterize(icon(snapshot(battery: .level(fraction: 0.09, isCharging: false)), full))
        XCTAssertGreaterThan(inkPixelCount(bitmap), inkPixelCount(single))
    }

    // MARK: Network

    func testPreciseWiFiStatesCollapseToThePlainFanUntilDistinguished() throws {
        // The same signal strength on an ordinary connection: a collapsed state has
        // to keep the fan and the lit dots it would have had.
        let plain = try png(icon(snapshot(wifi: .connected(level: 2))))
        let cases: [(DuoSystemStatusSnapshot.WiFi, WritableKeyPath<DuoStatusIconOptions, Bool>)] = [
            (.noInternet, \.distinguishesNoInternet),
            (.hotspot, \.distinguishesHotspot),
            (.temporary, \.distinguishesTemporaryNetwork),
            (.shared, \.distinguishesInternetSharing)
        ]

        for (wifi, keyPath) in cases {
            let state = snapshot(wifi: wifi)
            XCTAssertEqual(try png(icon(state)), plain, "\(wifi) must look like plain Wi-Fi by default")
            let distinguished = icon(state, options(keyPath, true))
            XCTAssertNotEqual(try png(distinguished), plain, "\(wifi) needs its own glyph once enabled")
            XCTAssertTrue(distinguished.isTemplate, "Network glyphs stay template images")

            // Only the matching option may promote a state to its own glyph.
            for (other, otherKeyPath) in cases where other != wifi {
                XCTAssertEqual(
                    try png(icon(state, options(otherKeyPath, true))), plain,
                    "\(other)'s option must not change \(wifi)"
                )
            }
        }
    }

    func testEthernetAndUnknownNetworksIgnoreTheWiFiGlyphOptions() throws {
        var all = DuoStatusIconOptions.default
        all.distinguishesNoInternet = true
        all.distinguishesHotspot = true
        all.distinguishesTemporaryNetwork = true
        all.distinguishesInternetSharing = true

        for kind in [DuoSystemStatusSnapshot.ConnectionKind.ethernet, .other] {
            let wired = snapshot(wifi: .noInternet, network: .connected, connectionKind: kind)
            XCTAssertEqual(try png(icon(wired)), try png(icon(wired, all)), "\(kind) keeps its own mark")
        }
        let unknown = snapshot(wifi: .hotspot, network: .unknown, connectionKind: nil)
        XCTAssertEqual(try png(icon(unknown)), try png(icon(unknown, all)))
    }

    func testBluetoothAudioGlyphReplacesTheNetworkMarkAndDropsTheTemplate() throws {
        let state = snapshot(volume: .init(scalar: 0.5, isBluetoothOutput: true))
        XCTAssertTrue(icon(state).isTemplate, "The glyph is off by default")

        let bluetooth = icon(state, options(\.showsBluetoothAudioGlyph, true))
        XCTAssertFalse(bluetooth.isTemplate, "The Bluetooth mark keeps its own color")
        XCTAssertNotEqual(try png(bluetooth), try png(icon(state)))

        // Wired output leaves the network mark alone even with the option on.
        let wired = snapshot(volume: .init(scalar: 0.5))
        XCTAssertEqual(
            try png(icon(wired, options(\.showsBluetoothAudioGlyph, true))),
            try png(icon(wired))
        )
    }

    // MARK: Bottom dots

    func testBottomDotsSwitchBetweenWiFiLevelAndVolume() throws {
        let loud = snapshot(wifi: .connected(level: 3), volume: .init(scalar: 0.8))
        let volumeOptions = options(\.bottomIndicator, .volume)
        XCTAssertNotEqual(try png(icon(loud)), try png(icon(loud, volumeOptions)))
        // Four lit dots are the same artwork whichever quantity feeds them.
        XCTAssertEqual(
            try png(icon(loud, volumeOptions)),
            try png(icon(snapshot(wifi: .connected(level: 4), volume: loud.volume)))
        )

        let muted = snapshot(wifi: .connected(level: 3), volume: .init(scalar: 0.8, isMuted: true))
        let silent = snapshot(wifi: .connected(level: 3), volume: .init(scalar: nil))
        XCTAssertEqual(try png(icon(muted, volumeOptions)), try png(icon(silent, volumeOptions)),
                       "Muted output draws the same unlit dots as a missing device")
        XCTAssertNotEqual(try png(icon(muted, volumeOptions)), try png(icon(loud, volumeOptions)))
    }

    // MARK: Defaults

    func testDefaultOptionsKeepTheShippingArtwork() throws {
        // Size and percentage are meant to be visible, so they stay at their
        // defaults here; every other new option must be invisible on a machine
        // whose state does not trigger it.
        var everything = DuoStatusIconOptions.default
        everything.distinguishesNoInternet = true
        everything.distinguishesHotspot = true
        everything.distinguishesTemporaryNetwork = true
        everything.distinguishesInternetSharing = true
        everything.showsBluetoothAudioGlyph = true

        for network in [DuoSystemStatusSnapshot.Network.connected, .disconnected, .requiresConnection, .unknown] {
            let state = snapshot(
                battery: .level(fraction: 0.62, isCharging: false),
                wifi: .connected(level: 2),
                network: network,
                volume: .init(scalar: 0.4)
            )
            XCTAssertEqual(try png(icon(state)), try png(icon(state, everything)), "Network: \(network)")
        }
    }

    // MARK: Helpers

    private func snapshot(
        battery: DuoSystemStatusSnapshot.Battery = .level(fraction: 0.62, isCharging: false),
        wifi: DuoSystemStatusSnapshot.WiFi = .connected(level: 2),
        wifiSignalLevel: Int = 2,
        network: DuoSystemStatusSnapshot.Network = .connected,
        connectionKind: DuoSystemStatusSnapshot.ConnectionKind? = .wifi,
        volume: DuoSystemStatusSnapshot.Volume = .init(scalar: 0.4)
    ) -> DuoSystemStatusSnapshot {
        DuoSystemStatusSnapshot(
            battery: battery, wifi: wifi, wifiSignalLevel: wifiSignalLevel, network: network,
            connectionKind: connectionKind, volume: volume
        )
    }

    private func options<Value>(
        _ keyPath: WritableKeyPath<DuoStatusIconOptions, Value>,
        _ value: Value
    ) -> DuoStatusIconOptions {
        var options = DuoStatusIconOptions.default
        options[keyPath: keyPath] = value
        return options
    }

    private func icon(
        _ snapshot: DuoSystemStatusSnapshot,
        _ options: DuoStatusIconOptions = .default
    ) -> NSImage {
        DuoStatusIcon.image(
            for: snapshot,
            options: options,
            appearance: .light,
            pointSize: NSSize(width: 96, height: 96)
        )
    }

    private func rasterize(_ image: NSImage) throws -> NSBitmapImageRep {
        let side = Int(image.size.width)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func png(_ image: NSImage) throws -> Data {
        try XCTUnwrap(rasterize(image).representation(using: .png, properties: [:]))
    }

    /// Bounding box of every pixel that carries ink, in bitmap coordinates.
    private func inkBounds(_ bitmap: NSBitmapImageRep) -> NSRect? {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        forEachInkPixel(bitmap) { x, y in
            minX = min(minX, CGFloat(x))
            maxX = max(maxX, CGFloat(x) + 1)
            minY = min(minY, CGFloat(y))
            maxY = max(maxY, CGFloat(y) + 1)
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func inkPixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        forEachInkPixel(bitmap) { _, _ in count += 1 }
        return count
    }

    private func forEachInkPixel(_ bitmap: NSBitmapImageRep, body: (Int, Int) -> Void) {
        for row in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let alpha = bitmap.colorAt(x: x, y: row)?.alphaComponent, alpha > 0.02 else { continue }
                // NSBitmapImageRep addresses rows from the top down.
                body(x, bitmap.pixelsHigh - row - 1)
            }
        }
    }

    /// The most saturated pixel, which is the status-colored battery ring when
    /// one is in use.
    private func strongestChroma(_ image: NSImage) throws -> NSColor {
        let bitmap = try rasterize(image)
        var best: NSColor?
        var bestChroma: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5 else { continue }
                let components = [color.redComponent, color.greenComponent, color.blueComponent]
                let chroma = (components.max() ?? 0) - (components.min() ?? 0)
                if chroma > bestChroma {
                    bestChroma = chroma
                    best = color
                }
            }
        }
        return try XCTUnwrap(best, "The image has no colored pixel")
    }
}
