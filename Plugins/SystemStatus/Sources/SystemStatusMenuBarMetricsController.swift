import AppKit
import Combine
import MacToolsPluginKit

struct SystemStatusMenuBarMetricBlock: Equatable {
    let kind: SystemStatusMetricKind
    let label: String
    let values: [String]
    let horizontalValue: String

    init(
        kind: SystemStatusMetricKind,
        label: String,
        values: [String],
        horizontalValue: String? = nil
    ) {
        self.kind = kind
        self.label = label
        self.values = values
        self.horizontalValue = horizontalValue ?? values.joined(separator: " ")
    }

    var verticalLabelLines: [String] {
        label.map(String.init)
    }
}

enum SystemStatusMenuBarMetricsFormatter {
    static func blocks(
        snapshot: SystemStatusSnapshot,
        kinds: [SystemStatusMetricKind]
    ) -> [SystemStatusMenuBarMetricBlock] {
        kinds.compactMap {
            block(for: $0, snapshot: snapshot)
        }
    }

    static func text(
        snapshot: SystemStatusSnapshot,
        kinds: [SystemStatusMetricKind]
    ) -> String {
        blocks(snapshot: snapshot, kinds: kinds)
            .map { "\($0.label) \($0.horizontalValue)" }
            .joined(separator: " | ")
    }

    static func tooltip(
        snapshot: SystemStatusSnapshot,
        kinds: [SystemStatusMetricKind]
    ) -> String {
        let details = blocks(snapshot: snapshot, kinds: kinds)
            .map { "\($0.label) \($0.horizontalValue)" }
        guard !details.isEmpty else {
            return "System Status"
        }

        return (["System Status"] + details).joined(separator: "\n")
    }

    private static func block(
        for kind: SystemStatusMetricKind,
        snapshot: SystemStatusSnapshot
    ) -> SystemStatusMenuBarMetricBlock? {
        switch kind {
        case .cpu:
            let percent = compactPercent(snapshot.cpu.usage)
            let temperature = compactTemperature(snapshot.cpu.temperatureCelsius)
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "CPU",
                values: [percent, temperature ?? "—"],
                horizontalValue: horizontalValue(percent: percent, secondary: temperature)
            )
        case .gpu:
            guard snapshot.gpu.isAvailable else {
                return SystemStatusMenuBarMetricBlock(
                    kind: kind,
                    label: "GPU",
                    values: ["—", "—"],
                    horizontalValue: "—"
                )
            }

            let percent = compactPercent(snapshot.gpu.usage)
            let temperature = compactTemperature(snapshot.gpu.temperatureCelsius)
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "GPU",
                values: [percent, temperature ?? "—"],
                horizontalValue: horizontalValue(percent: percent, secondary: temperature)
            )
        case .memory:
            let percent = compactPercent(snapshot.memory.usage)
            let values = [percent, compactAmount(snapshot.memory.usedBytes)]
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "RAM",
                values: values
            )
        case .disk:
            let percent = compactPercent(snapshot.disk.usage)
            let activity = combinedDiskBytesPerSecond(snapshot.disk).map {
                "↕\(compactAmount($0))"
            } ?? "—"
            let values = [percent, activity]
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "DSK",
                values: values
            )
        case .battery:
            guard snapshot.battery.isAvailable else {
                return SystemStatusMenuBarMetricBlock(
                    kind: kind,
                    label: "BAT",
                    values: ["—", "—"],
                    horizontalValue: "—"
                )
            }

            let percent = compactPercent(snapshot.battery.level)
            let values = [percent, batterySecondaryValue(snapshot.battery)]
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "BAT",
                values: values
            )
        case .network:
            let download = "↓\(compactAmount(snapshot.network.downloadBytesPerSecond))"
            let upload = "↑\(compactAmount(snapshot.network.uploadBytesPerSecond))"
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "NET",
                values: [download, upload]
            )
        case .topProcesses:
            return nil
        }
    }

    private static func horizontalValue(percent: String, secondary: String?) -> String {
        guard let secondary else {
            return percent
        }

        return "\(percent) \(secondary)"
    }

    private static func compactPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "—"
        }

        return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    private static func compactTemperature(_ celsius: Double?) -> String? {
        guard let celsius, celsius.isFinite else {
            return nil
        }

        return "\(Int(celsius.rounded()))°"
    }

    private static func compactAmount(_ bytes: UInt64?) -> String {
        guard let bytes else {
            return "—"
        }

        let units = ["B", "K", "M", "G", "T", "P", "E"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        while true {
            if value < 10, unitIndex > 0 {
                let rounded = (value * 10).rounded() / 10
                if rounded.rounded() == rounded {
                    return "\(Int(rounded))\(units[unitIndex])"
                }
                return String(format: "%.1f%@", rounded, units[unitIndex])
            }

            let rounded = value.rounded()
            if rounded >= 100, unitIndex < units.count - 1 {
                value /= 1024
                unitIndex += 1
                continue
            }

            return "\(Int(rounded))\(units[unitIndex])"
        }
    }

    private static func combinedDiskBytesPerSecond(_ disk: SystemStatusDiskSnapshot) -> UInt64? {
        guard disk.readBytesPerSecond != nil || disk.writeBytesPerSecond != nil else {
            return nil
        }

        let (total, overflow) = (disk.readBytesPerSecond ?? 0).addingReportingOverflow(
            disk.writeBytesPerSecond ?? 0
        )
        return overflow ? UInt64.max : total
    }

    private static func batterySecondaryValue(_ battery: SystemStatusBatterySnapshot) -> String {
        if let power = compactBatteryPower(battery.batteryPowerWatts) {
            return power
        }
        if let temperature = compactTemperature(battery.temperatureCelsius) {
            return temperature
        }
        return "—"
    }

    private static func compactBatteryPower(_ watts: Double?) -> String? {
        guard let watts, watts.isFinite else {
            return nil
        }

        let magnitude = abs(watts)
        if magnitude < 0.05 {
            return "0W"
        }

        let value = Int(magnitude.rounded())
        return "\(value)W"
    }
}

final class SystemStatusMenuBarMetricsView: NSView {
    private enum Layout {
        static let topInset: CGFloat = 1
        static let bottomInset: CGFloat = 1
        static let horizontalInset: CGFloat = 4
        static let interMetricSpacing: CGFloat = 4
        static let minimumMetricWidth: CGFloat = 24
        static let verticalLabelValueSpacing: CGFloat = 2
    }

    var menuBarLayout: SystemStatusMenuBarLayout = .horizontal {
        didSet {
            guard menuBarLayout != oldValue else {
                return
            }

            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var blocks: [SystemStatusMenuBarMetricBlock] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth(for: blocks), height: NSStatusBar.system.thickness)
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let metricWidths = blocks.map(metricWidth)
        var x = Layout.horizontalInset

        for index in blocks.indices {
            let width = metricWidths[index]
            draw(blocks[index], in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width

            guard index < blocks.index(before: blocks.endIndex) else {
                continue
            }

            x += Layout.interMetricSpacing
        }
    }

    private var labelFont: NSFont {
        NSFont.systemFont(ofSize: 7, weight: .regular)
    }

    private var valueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    }

    private var verticalLabelFont: NSFont {
        NSFont.systemFont(ofSize: 5.5, weight: .semibold)
    }

    private var verticalValueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
    }

    private func draw(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        switch menuBarLayout {
        case .horizontal:
            drawStandard(block, in: rect)
        case .vertical:
            drawVertical(block, in: rect)
        }
    }

    private func drawStandard(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let label = attributedText(
            block.label,
            font: labelFont,
            color: .labelColor,
            kern: 0.2
        )
        let value = attributedText(
            block.horizontalValue,
            font: valueFont,
            color: .labelColor
        )

        let labelSize = label.size()
        let valueSize = value.size()
        let labelRect = NSRect(
            x: rect.minX + (rect.width - labelSize.width) / 2,
            y: Layout.topInset,
            width: labelSize.width,
            height: labelSize.height
        )
        let valueRect = NSRect(
            x: rect.minX + (rect.width - valueSize.width) / 2,
            y: max(Layout.topInset + labelSize.height - 1, rect.maxY - valueSize.height - Layout.bottomInset),
            width: valueSize.width,
            height: valueSize.height
        )

        label.draw(in: labelRect)
        value.draw(in: valueRect)
    }

    private func drawVertical(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let labelLines = block.verticalLabelLines.map {
            attributedText($0, font: verticalLabelFont, color: .labelColor)
        }
        let lines = verticalValues(for: block).map {
            attributedText($0, font: verticalValueFont, color: .labelColor)
        }
        let labelLineSizes = labelLines.map { $0.size() }
        let labelHeight = labelLineSizes.reduce(CGFloat(0)) { $0 + $1.height }
        let lineSizes = lines.map { $0.size() }
        let lineHeights = lines.map { $0.size().height }
        let totalHeight = lineHeights.reduce(0, +)
        let labelWidth = verticalLabelColumnWidth
        let contentWidth = labelWidth + Layout.verticalLabelValueSpacing + verticalValueColumnWidth
        let contentX = rect.midX - contentWidth / 2

        var labelY = rect.midY - labelHeight / 2
        for (line, size) in zip(labelLines, labelLineSizes) {
            line.draw(in: NSRect(
                x: contentX + (labelWidth - size.width) / 2,
                y: labelY,
                width: size.width,
                height: size.height
            ))
            labelY += size.height
        }

        var y = rect.midY - totalHeight / 2

        for (line, lineSize) in zip(lines, lineSizes) {
            line.draw(in: NSRect(
                x: contentX + labelWidth + Layout.verticalLabelValueSpacing,
                y: y,
                width: lineSize.width,
                height: lineSize.height
            ))
            y += lineSize.height
        }
    }

    private func metricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        switch menuBarLayout {
        case .horizontal:
            return horizontalMetricWidth(block)
        case .vertical:
            return verticalMetricWidth(block)
        }
    }

    private func horizontalMetricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        let labelWidth = attributedText(
            block.label,
            font: labelFont,
            color: .labelColor
        ).size().width
        let valueWidth = attributedText(
            widthReservationValues(for: block.kind).joined(separator: " "),
            font: valueFont,
            color: .labelColor
        ).size().width
        return ceil(max(Layout.minimumMetricWidth, labelWidth, valueWidth))
    }

    private func verticalMetricWidth(_: SystemStatusMenuBarMetricBlock) -> CGFloat {
        return ceil(max(
            Layout.minimumMetricWidth,
            verticalLabelColumnWidth + Layout.verticalLabelValueSpacing + verticalValueColumnWidth
        ))
    }

    private var verticalLabelColumnWidth: CGFloat {
        attributedText("M", font: verticalLabelFont, color: .labelColor).size().width
    }

    private var verticalValueColumnWidth: CGFloat {
        ["100%", "999°", "↓9.9M", "↑9.9M", "↕9.9M", "999W"].reduce(CGFloat(0)) { width, value in
            max(
                width,
                attributedText(value, font: verticalValueFont, color: .labelColor).size().width
            )
        }
    }

    private func widthReservationValues(for kind: SystemStatusMetricKind) -> [String] {
        switch kind {
        case .cpu, .gpu:
            return ["100%", "999°"]
        case .memory:
            return ["100%", "9.9M"]
        case .disk:
            return ["100%", "↕9.9M"]
        case .battery:
            return ["100%", "999W"]
        case .network:
            return ["↓9.9M", "↑9.9M"]
        case .topProcesses:
            return []
        }
    }

    private func verticalValues(for block: SystemStatusMenuBarMetricBlock) -> [String] {
        var values = Array(block.values.prefix(2))
        while values.count < 2 {
            values.append("—")
        }
        return values
    }

    private func preferredWidth(for blocks: [SystemStatusMenuBarMetricBlock]) -> CGFloat {
        guard !blocks.isEmpty else {
            return 0
        }

        let metricsWidth = blocks.reduce(CGFloat(0)) { partialResult, block in
            partialResult + metricWidth(block)
        }
        let spacingCount = CGFloat(max(blocks.count - 1, 0))
        let spacingWidth = spacingCount * Layout.interMetricSpacing
        return ceil(metricsWidth + spacingWidth + Layout.horizontalInset * 2)
    }

    private func attributedText(
        _ string: String,
        font: NSFont,
        color: NSColor,
        kern: CGFloat = 0
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: kern
            ]
        )
    }
}

@MainActor
final class SystemStatusMenuBarMetricsController: NSObject {
    private static let autosaveName = "MacTools.SystemStatus.MenuBarMetrics"

    private let viewModel: SystemStatusViewModel
    private let settingsController: SystemStatusSettingsController
    var requestConfigurationPresentation: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem?
    private var metricsView: SystemStatusMenuBarMetricsView?
    private var isActive = false

    init(
        viewModel: SystemStatusViewModel,
        settingsController: SystemStatusSettingsController
    ) {
        self.viewModel = viewModel
        self.settingsController = settingsController
        super.init()
        observeState()
    }

    func activate() {
        isActive = true
        render(
            configuration: settingsController.configuration,
            snapshot: viewModel.snapshot
        )
    }

    func stop() {
        isActive = false
        viewModel.stopMenuBar()
        removeStatusItem()
    }

    private func observeState() {
        settingsController.$configuration
            .removeDuplicates()
            .combineLatest(viewModel.$snapshot.removeDuplicates())
            .sink { [weak self] configuration, snapshot in
                self?.render(configuration: configuration, snapshot: snapshot)
            }
            .store(in: &cancellables)
    }

    private func render(
        configuration: SystemStatusConfiguration,
        snapshot: SystemStatusSnapshot
    ) {
        guard isActive else {
            removeStatusItem()
            return
        }

        let kinds = configuration.visibleMenuBarMetricKinds
        guard !kinds.isEmpty else {
            viewModel.stopMenuBar()
            removeStatusItem()
            return
        }

        viewModel.startMenuBar(requiresSlowSampling: kinds.requiresMenuBarSlowSampling)
        let blocks = SystemStatusMenuBarMetricsFormatter.blocks(
            snapshot: snapshot,
            kinds: kinds
        )
        guard !blocks.isEmpty else {
            viewModel.stopMenuBar()
            removeStatusItem()
            return
        }

        let statusItem = ensureStatusItem()

        guard let button = statusItem.button else {
            return
        }

        let metricsView = ensureMetricsView(in: button)
        metricsView.menuBarLayout = configuration.menuBarLayout
        metricsView.blocks = blocks
        statusItem.length = metricsView.intrinsicContentSize.width
        metricsView.frame = button.bounds
        button.toolTip = SystemStatusMenuBarMetricsFormatter.tooltip(
            snapshot: snapshot,
            kinds: kinds
        )
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }

        PluginPresentationSafety.prepareForWindowOrdering()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.image = nil
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
        }

        statusItem = item
        return item
    }

    private func ensureMetricsView(in button: NSStatusBarButton) -> SystemStatusMenuBarMetricsView {
        if let metricsView {
            return metricsView
        }

        let view = SystemStatusMenuBarMetricsView()
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        metricsView = view
        return view
    }

    private func removeStatusItem() {
        guard let statusItem else {
            return
        }

        PluginPresentationSafety.prepareForWindowOrdering()
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        metricsView = nil
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        requestConfigurationPresentation?()
    }
}

private extension Array where Element == SystemStatusMetricKind {
    var requiresMenuBarSlowSampling: Bool {
        contains { kind in
            switch kind {
            case .gpu, .disk, .battery:
                return true
            case .cpu, .network, .memory, .topProcesses:
                return false
            }
        }
    }
}
