import SwiftUI

/// A stable numeric readout with a subordinate unit, shared by settings and widgets.
public struct PluginMetricValue: View {
    private let value: String
    private let unit: String
    private let isProminent: Bool
    private let unitColor: Color

    public init(
        _ value: String,
        unit: String,
        isProminent: Bool = false,
        unitColor: Color = .secondary
    ) {
        self.value = value
        self.unit = unit
        self.isProminent = isProminent
        self.unitColor = unitColor
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font((isProminent ? PluginTypography.prominentMetric : .metric).font)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if !unit.isEmpty {
                Text(unit)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(unitColor)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
