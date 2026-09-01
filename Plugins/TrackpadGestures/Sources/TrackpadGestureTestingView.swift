import AppKit
import SwiftUI
import MacToolsPluginKit

struct TrackpadGestureTestingPanel: View {
    @ObservedObject var model: TrackpadGestureTestingModel
    @ObservedObject var store: TrackpadGestureStore
    let localization: PluginLocalization
    let actionTitle: (TrackpadGestureAction) -> String
    let onSetMode: (TrackpadGestureTestingMode?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Button {
                    onSetMode(.allGestures)
                } label: {
                    Label(
                        localization.string(
                            "settings.testing.mode.all",
                            defaultValue: "测试全部"
                        ),
                        systemImage: model.mode == .allGestures
                            ? "checkmark.circle.fill"
                            : "waveform.path"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityAddTraits(
                    modeAccessibilityState.isAllGesturesSelected ? .isSelected : []
                )
                .accessibilityValue(Text(modeAccessibilityValue(
                    isSelected: modeAccessibilityState.isAllGesturesSelected
                )))

                Picker(
                    localization.string(
                        "settings.testing.mode.practice",
                        defaultValue: "练习一个手势"
                    ),
                    selection: practiceGestureBinding
                ) {
                    ForEach(TrackpadGesture.configurableCases) { gesture in
                        Text(gesture.title(localization: localization)).tag(gesture)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
                .accessibilityAddTraits(
                    modeAccessibilityState.selectedPracticeGesture != nil ? .isSelected : []
                )
                .accessibilityValue(Text(modeAccessibilityValue(
                    isSelected: modeAccessibilityState.selectedPracticeGesture != nil
                )))

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                if model.orderedSnapshots.count > 1 {
                    Picker(
                        localization.string(
                            "settings.testing.device",
                            defaultValue: "触控板"
                        ),
                        selection: deviceBinding
                    ) {
                        ForEach(model.orderedSnapshots, id: \.deviceID) { snapshot in
                            Text(deviceTitle(snapshot)).tag(snapshot.deviceID as UInt64?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 140, idealWidth: 180, maxWidth: 220)
                } else if let snapshot = model.selectedSnapshot {
                    Text(deviceTitle(snapshot))
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                }
            }

            if case let .practice(gesture) = model.mode {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(gesture.title(localization: localization))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(practiceSubtitle(for: gesture))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
            }

            TrackpadVirtualTrackpadView(
                snapshot: model.selectedSnapshot,
                practiceGesture: model.mode?.practiceGesture,
                localization: localization
            )
            .frame(height: 230)

            Text(statusText)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(statusText))
        }
        .pluginSettingsListRowPadding(interactive: true)
        .pluginSettingsCardBackground(.standard)
        .onChange(of: model.latestRejectionAnnouncement) { previous, current in
            guard TrackpadGestureTestingRejectionAnnouncementPolicy.shouldAnnounce(
                previous: previous,
                current: current
            ), let current else {
                return
            }
            announceRejectedTestGesture(current)
        }
    }

    private var practiceGestureBinding: Binding<TrackpadGesture> {
        Binding(
            get: {
                model.mode?.practiceGesture
                    ?? store.lastTestGesture
                    ?? store.mappings.first?.gesture
                    ?? .tipTapLeftOneFixed
            },
            set: { onSetMode(.practice($0)) }
        )
    }

    private var modeAccessibilityState: TrackpadGestureTestingModeAccessibilityState {
        TrackpadGestureTestingModeAccessibilityState(mode: model.mode)
    }

    private var deviceBinding: Binding<UInt64?> {
        Binding(
            get: { model.selectedDeviceID },
            set: { deviceID in
                if let deviceID {
                    model.selectDevice(deviceID)
                }
            }
        )
    }

    private func practiceSubtitle(for gesture: TrackpadGesture) -> String {
        if let mapping = store.mapping(for: gesture) {
            return localization.format(
                "settings.testing.practice.mappingFormat",
                defaultValue: "当前映射：%@。测试期间不会执行。",
                actionTitle(mapping.action)
            )
        }
        return localization.string(
            "settings.testing.practice.unmapped",
            defaultValue: "此手势尚未映射；你仍可在这里练习识别。"
        )
    }

    private var statusText: String {
        let presentation = TrackpadGestureTestingStatusPresentationResolver.resolve(
            snapshot: model.selectedSnapshot,
            retainedRecognition: model.selectedRecognizedGesture,
            retainedRejection: model.selectedRejection
        )
        switch presentation {
        case let .guide(availability):
            return availability.statusText(localization: localization)
        case let .status(status):
            return statusText(for: status)
        }
    }

    private func statusText(for status: TrackpadGestureTestingStatus) -> String {
        switch status {
        case .waiting:
            return localization.string(
                "settings.testing.surface.waiting",
                defaultValue: "请在触控板上放下手指。接触点只在内存中显示。"
            )
        case let .recognized(recognized):
            return localization.format(
                "settings.testing.surface.recognizedFormat",
                defaultValue: "已识别：%@。可以继续测试下一个手势。",
                recognized.title(localization: localization)
            )
        case .noContacts:
            return localization.string(
                "settings.testing.surface.noContacts",
                defaultValue: "没有接触点。放下手指即可开始。"
            )
        case let .contactCount(count):
            return localization.format(
                "settings.testing.surface.contactCountFormat",
                defaultValue: "检测到 %d 个接触点；继续完成手势。",
                count
            )
        case let .phase(phase, gesture):
            return phase.statusText(gesture: gesture, localization: localization)
        }
    }

    private func modeAccessibilityValue(isSelected: Bool) -> String {
        localization.string(
            isSelected
                ? "settings.testing.mode.accessibility.active"
                : "settings.testing.mode.accessibility.inactive",
            defaultValue: isSelected ? "当前模式" : "未启用"
        )
    }

    private func announceRejectedTestGesture(
        _ rejection: TrackpadGestureTestingRejection
    ) {
        let announcement = statusText(for: .phase(
            .rejected(rejection.reason),
            gesture: rejection.gesture
        ))
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func deviceTitle(_ snapshot: TrackpadGestureTestSnapshot) -> String {
        let suffix = String(snapshot.deviceID, radix: 16).suffix(4).uppercased()
        if snapshot.descriptor?.isBuiltIn == true {
            return localization.format(
                "settings.testing.device.builtInFormat",
                defaultValue: "内置触控板 · %@",
                String(suffix)
            )
        }
        switch snapshot.descriptor?.transport {
        case .bluetooth:
            return localization.format(
                "settings.testing.device.bluetoothFormat",
                defaultValue: "妙控板（蓝牙）· %@",
                String(suffix)
            )
        case .usb:
            return localization.format(
                "settings.testing.device.usbFormat",
                defaultValue: "妙控板（USB）· %@",
                String(suffix)
            )
        default:
            return localization.format(
                "settings.testing.device.genericFormat",
                defaultValue: "触控板 · %@",
                String(suffix)
            )
        }
    }
}

private struct TrackpadVirtualTrackpadView: View {
    let snapshot: TrackpadGestureTestSnapshot?
    let practiceGesture: TrackpadGesture?
    let localization: PluginLocalization

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var snapshotReceivedAt = ProcessInfo.processInfo.systemUptime

    var body: some View {
        GeometryReader { proxy in
            let insetSize = CGSize(
                width: max(proxy.size.width - 24, 0),
                height: max(proxy.size.height - 24, 0)
            )
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.secondary.opacity(colorSchemeContrast == .increased ? 0.12 : 0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(colorSchemeContrast == .increased ? 0.55 : 0.20),
                                lineWidth: colorSchemeContrast == .increased ? 2 : 1
                            )
                    }

                if let snapshot {
                    guideOverlay(snapshot: snapshot, size: insetSize)
                        .frame(width: insetSize.width, height: insetSize.height)

                    ForEach(snapshot.contacts, id: \.identifier) { contact in
                        let role = contactRole(contact, recognition: snapshot.recognition)
                        TrackpadContactDot(role: role, identifier: contact.identifier)
                            .position(TrackpadCoordinateProjector.project(contact, in: insetSize))
                            .accessibilityLabel(Text(contactAccessibilityLabel(
                                contact,
                                role: role
                            )))
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left")
                            .font(.system(size: 28))
                        Text(localization.string(
                            "settings.testing.surface.waiting.short",
                            defaultValue: "等待接触"
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(localization.string(
            "settings.testing.surface.accessibilityLabel",
            defaultValue: "实时虚拟触控板"
        )))
        .onChange(of: snapshot?.timestamp, initial: true) {
            snapshotReceivedAt = ProcessInfo.processInfo.systemUptime
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }

    @ViewBuilder
    private func guideOverlay(
        snapshot: TrackpadGestureTestSnapshot,
        size: CGSize
    ) -> some View {
        if let recognition = snapshot.recognition, practiceGesture != nil {
            let guide = TrackpadPracticeGuideGeometry.make(snapshot: recognition)
            ZStack {
                ForEach(Array(guide.unavailableRanges.enumerated()), id: \.offset) { _, range in
                    let width = max(0, range.upperBound - range.lowerBound) * size.width
                    Rectangle()
                        .fill(Color.secondary.opacity(0.055))
                        .frame(width: width)
                        .position(
                            x: (range.lowerBound + range.upperBound) * 0.5 * size.width,
                            y: size.height * 0.5
                        )
                        .accessibilityHidden(true)
                }
                ForEach(Array(guide.regions.enumerated()), id: \.offset) { _, region in
                    let width = max(0, region.xRange.upperBound - region.xRange.lowerBound)
                        * size.width
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay(alignment: .top) {
                            Text(region.region.guideLabel(localization: localization))
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .padding(4)
                        }
                        .frame(width: width)
                        .position(
                            x: (region.xRange.lowerBound + region.xRange.upperBound)
                                * 0.5 * size.width,
                            y: size.height * 0.5
                        )
                }

                ForEach(recognition.anchorContacts, id: \.identifier) { contact in
                    let haloSize = TrackpadMovementHaloGeometry.size(
                        normalizedRadius: guide.anchorToleranceRadius,
                        surfaceSize: size
                    )
                    Ellipse()
                        .stroke(
                            Color.accentColor.opacity(0.65),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                        .frame(width: haloSize.width, height: haloSize.height)
                        .position(TrackpadCoordinateProjector.project(contact, in: size))
                        .accessibilityHidden(true)
                }

                ForEach(recognition.candidateContacts, id: \.identifier) { contact in
                    let haloSize = TrackpadMovementHaloGeometry.size(
                        normalizedRadius: guide.candidateToleranceRadius,
                        surfaceSize: size
                    )
                    Ellipse()
                        .stroke(
                            Color.orange.opacity(0.75),
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                        )
                        .frame(width: haloSize.width, height: haloSize.height)
                        .position(TrackpadCoordinateProjector.project(contact, in: size))
                        .accessibilityHidden(true)
                }

                VStack {
                    HStack {
                        Label(
                            localization.format(
                                "settings.testing.surface.requiredCountFormat",
                                defaultValue: "%d 指",
                                recognition.requiredContactCount
                            ),
                            systemImage: recognition.gesture.physicalClickFingerCount == nil
                                ? "hand.tap"
                                : "computermouse"
                        )
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        Spacer()
                    }
                    Spacer()
                    if recognition.phase == .waitingForSecondTap {
                        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                            progressCue(
                                snapshot: snapshot,
                                recognition: recognition,
                                now: snapshot.timestamp + max(
                                    ProcessInfo.processInfo.systemUptime - snapshotReceivedAt,
                                    0
                                )
                            )
                        }
                    } else {
                        progressCue(
                            snapshot: snapshot,
                            recognition: recognition,
                            now: snapshot.timestamp
                        )
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func progressCue(
        snapshot: TrackpadGestureTestSnapshot,
        recognition: TrackpadGestureRecognitionSnapshot,
        now: TimeInterval
    ) -> some View {
        if let startedAt = recognition.startedAt, let deadline = recognition.deadline {
            let timing = TrackpadGestureTimingProgress.make(
                startedAt: startedAt,
                deadline: deadline,
                now: now
            )
            let remainingText = localization.format(
                "settings.testing.progress.durationFormat",
                defaultValue: "%.0f 毫秒",
                timing.remaining * 1_000
            )
            let timingText = recognition.phase == .waitingForSecondTap
                && timing.remaining == 0
                ? localization.string(
                    "settings.testing.progress.expired",
                    defaultValue: "时间已到，请重新开始"
                )
                : remainingText
            HStack(spacing: 8) {
                ProgressView(value: timing.fraction)
                    .progressViewStyle(.linear)
                Text(timingText)
                .font(PluginSettingsTheme.Typography.monospacedValue)
            }
            .accessibilityLabel(Text(recognition.phase.progressLabel(localization: localization)))
            .accessibilityValue(Text(timingText))
        } else if recognition.gesture.physicalClickFingerCount != nil {
            Label(
                snapshot.contacts.count == recognition.requiredContactCount
                    ? localization.string(
                        "settings.testing.surface.pressNow",
                        defaultValue: "现在按下触控板"
                    )
                    : localization.format(
                        "settings.testing.surface.placeCountFormat",
                        defaultValue: "请放下 %d 指",
                        recognition.requiredContactCount
                    ),
                systemImage: "arrow.down.to.line.compact"
            )
            .font(PluginSettingsTheme.Typography.rowDescription)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private func contactRole(
        _ contact: TrackpadContactSnapshot,
        recognition: TrackpadGestureRecognitionSnapshot?
    ) -> TrackpadContactRole {
        TrackpadContactRoleResolver.resolve(contact, recognition: recognition)
    }

    private func contactAccessibilityLabel(
        _ contact: TrackpadContactSnapshot,
        role: TrackpadContactRole
    ) -> String {
        localization.format(
            "settings.testing.surface.contactAccessibilityFormat",
            defaultValue: "%@，位置 %.0f%%、%.0f%%",
            role.title(localization: localization),
            contact.x * 100,
            contact.y * 100
        )
    }
}

extension TrackpadContactRole {
    func title(localization: PluginLocalization) -> String {
        switch self {
        case .fixed:
            localization.string("settings.testing.role.fixed", defaultValue: "固定手指")
        case .added:
            localization.string("settings.testing.role.added", defaultValue: "轻点手指")
        case .contact:
            localization.string("settings.testing.role.contact", defaultValue: "接触点")
        }
    }
}

private struct TrackpadContactDot: View {
    let role: TrackpadContactRole
    let identifier: Int

    var body: some View {
        ZStack {
            switch role {
            case .fixed:
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.blue)
                    .frame(width: 30, height: 30)
                Text("F")
            case .added:
                Circle()
                    .fill(Color.orange)
                    .frame(width: 30, height: 30)
                Text("T")
            case .contact:
                Diamond()
                    .fill(Color.accentColor)
                    .frame(width: 30, height: 30)
                Text(String(identifier % 10))
            }
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private extension TipTapRegion {
    func guideLabel(localization: PluginLocalization) -> String {
        switch self {
        case .left:
            localization.string("settings.testing.guide.left", defaultValue: "左侧轻点区")
        case .middle:
            localization.string("settings.testing.guide.middle", defaultValue: "中间轻点区")
        case .right:
            localization.string("settings.testing.guide.right", defaultValue: "右侧轻点区")
        }
    }
}

private extension TrackpadGestureRecognitionPhase {
    func statusText(
        gesture: TrackpadGesture,
        localization: PluginLocalization
    ) -> String {
        switch self {
        case .waitingForReset:
            localization.string("settings.testing.status.reset", defaultValue: "请先抬起所有手指。")
        case .ready:
            localization.string("settings.testing.status.ready", defaultValue: "已就绪，请放下手指。")
        case .acquiring:
            localization.string("settings.testing.status.acquiring", defaultValue: "继续放下所需手指。")
        case .settling:
            localization.string("settings.testing.status.settling", defaultValue: "保持固定手指不动。")
        case .armed:
            localization.string("settings.testing.status.armed", defaultValue: "固定手指已就绪；现在添加轻点手指。")
        case .candidate:
            localization.string("settings.testing.status.candidate", defaultValue: "轻点已检测；抬起轻点手指。")
        case let .rejected(reason):
            reason.practiceStatusText(localization: localization)
        case .tracking:
            localization.string("settings.testing.status.tracking", defaultValue: "保持位置，然后抬起手指。")
        case .waitingForSecondTap:
            localization.string("settings.testing.status.secondTap", defaultValue: "请在时间内完成第二次轻点。")
        case .holding:
            localization.string("settings.testing.status.holding", defaultValue: "继续保持，直到长按完成。")
        case .recognized:
            localization.format(
                "settings.testing.surface.recognizedFormat",
                defaultValue: "已识别：%@。可以继续测试下一个手势。",
                gesture.title(localization: localization)
            )
        case .physicalClick:
            localization.string("settings.testing.status.physicalClick", defaultValue: "放下所需手指，然后按下触控板。")
        }
    }

    func progressLabel(localization: PluginLocalization) -> String {
        switch self {
        case .waitingForSecondTap:
            localization.string("settings.testing.progress.secondTap", defaultValue: "第二次轻点时间")
        case .holding:
            localization.string("settings.testing.progress.hold", defaultValue: "长按进度")
        default:
            localization.string("settings.testing.progress.tap", defaultValue: "手势时间")
        }
    }
}

extension TipTapEpisodeRejectionReason {
    func practiceStatusText(localization: PluginLocalization) -> String {
        switch self {
        case .fixedFingersNotSettled:
            localization.string(
                "settings.testing.status.rejected.fixedNotSettled",
                defaultValue: "固定手指尚未稳定；保持不动后再添加轻点手指。"
            )
        case .fixedFingersBecameUnstable:
            localization.string(
                "settings.testing.status.rejected.fixedUnstable",
                defaultValue: "固定手指已移动或抬起；请先抬起所有手指再重试。"
            )
        case .tooBrief:
            localization.string(
                "settings.testing.status.rejected.tooBrief",
                defaultValue: "轻点时间太短；稍微停留后再抬起。"
            )
        case .tooLong:
            localization.string(
                "settings.testing.status.rejected.tooLong",
                defaultValue: "轻点时间太长；更快抬起轻点手指。"
            )
        case .movedTooFar:
            localization.string(
                "settings.testing.status.rejected.movedTooFar",
                defaultValue: "轻点手指移动过远；轻点时保持原位。"
            )
        case .wrongRegion:
            localization.string(
                "settings.testing.status.rejected.wrongRegion",
                defaultValue: "轻点位置不在目标区域；请在高亮区域重试。"
            )
        case .extraContact:
            localization.string(
                "settings.testing.status.rejected.extraContact",
                defaultValue: "检测到额外手指；抬起新增手指后仅用一根轻点。"
            )
        }
    }
}

extension TrackpadPracticeGuideAvailability {
    func statusText(localization: PluginLocalization) -> String {
        switch self {
        case .notApplicable, .targetAvailable:
            return ""
        case let .waitingForAnchors(required, current):
            return localization.format(
                "settings.testing.guide.waitingForAnchorsFormat",
                defaultValue: "先稳定放下固定手指（%d/%d），目标区域随后显示。",
                current,
                required
            )
        case .middleRequiresWiderSpan:
            return localization.string(
                "settings.testing.guide.middleRequiresWiderSpan",
                defaultValue: "固定手指间距太窄；稍微分开后，中间目标区域会显示。"
            )
        case .targetOutsideSurface:
            return localization.string(
                "settings.testing.guide.targetOutsideSurface",
                defaultValue: "固定手指太靠近边缘；向触控板中央移动后重试。"
            )
        }
    }
}
