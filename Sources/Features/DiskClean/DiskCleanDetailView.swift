import SwiftUI

struct DiskCleanDetailView: View {
    @ObservedObject var controller: DiskCleanController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            choiceControls
            actionBar
            statusSummary
            candidateList
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 480, alignment: .topLeading)
    }

    private var snapshot: DiskCleanControllerSnapshot {
        controller.snapshot
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("磁盘清理")
                .font(.system(size: 22, weight: .semibold))

            Text(snapshot.errorMessage ?? snapshot.subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(snapshot.errorMessage == nil ? Color.secondary : Color.red)
        }
    }

    private var choiceControls: some View {
        HStack(spacing: 16) {
            ForEach(DiskCleanChoice.allCases) { choice in
                Toggle(
                    choice.title,
                    isOn: Binding(
                        get: { snapshot.selectedChoices.contains(choice) },
                        set: { controller.setChoice(choice, isSelected: $0) }
                    )
                )
                .toggleStyle(.checkbox)
                .disabled(snapshot.isBusy)
            }

            Spacer()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                controller.scan()
            } label: {
                Label("扫描", systemImage: "magnifyingglass")
            }
            .disabled(!snapshot.canScan)

            Button {
                controller.cleanSelected(candidateIDs: cleanableCandidateIDs)
            } label: {
                Label("清理", systemImage: "trash")
            }
            .disabled(!snapshot.canClean)

            if snapshot.isBusy {
                Button {
                    controller.cancelCurrentOperation()
                } label: {
                    Label("停止", systemImage: "xmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var statusSummary: some View {
        if let scanResult = snapshot.scanResult {
            HStack(spacing: 16) {
                summaryTile(
                    title: "可清理",
                    value: "\(scanResult.cleanableCandidates.count) 项"
                )
                summaryTile(
                    title: "预计释放",
                    value: byteText(scanResult.cleanableSizeBytes)
                )
                summaryTile(
                    title: "已保护",
                    value: "\(scanResult.protectedCount) 项"
                )
            }
        }

        if let executionResult = snapshot.executionResult {
            HStack(spacing: 16) {
                summaryTile(title: "已删除", value: "\(executionResult.removedCount) 项")
                summaryTile(title: "已跳过", value: "\(executionResult.skippedCount) 项")
                summaryTile(title: "失败", value: "\(executionResult.failedCount) 项")
                summaryTile(title: "已释放", value: byteText(executionResult.reclaimedBytes))
            }
        }
    }

    private func summaryTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
        }
        .frame(minWidth: 96, alignment: .leading)
    }

    @ViewBuilder
    private var candidateList: some View {
        if let scanResult = snapshot.scanResult {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(scanResult.candidates) { candidate in
                        candidateRow(candidate)
                        Divider()
                    }
                }
            }
            .overlay {
                if scanResult.candidates.isEmpty {
                    Text("没有发现可清理项目")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Spacer()
        }
    }

    private func candidateRow(_ candidate: DiskCleanCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: candidate.safety.isCleanable ? "checkmark.circle.fill" : "shield.fill")
                .foregroundStyle(candidate.safety.isCleanable ? Color.green : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(candidate.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 12)
                    Text(byteText(candidate.sizeBytes))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text(candidate.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(safetyText(candidate.safety))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(candidate.safety.isCleanable ? Color.green : Color.secondary)
            }
        }
        .padding(.vertical, 9)
    }

    private var cleanableCandidateIDs: Set<DiskCleanCandidate.ID> {
        Set(snapshot.scanResult?.cleanableCandidates.map(\.id) ?? [])
    }

    private func safetyText(_ safety: DiskCleanSafetyStatus) -> String {
        switch safety {
        case .allowed:
            return "允许清理"
        case let .whitelisted(rule):
            return "白名单保护：\(rule)"
        case let .protected(reason):
            return "敏感数据保护：\(reason)"
        case let .invalid(reason):
            return "路径安全保护：\(reason)"
        case let .requiresAdmin(reason):
            return "需要管理员权限：\(reason)"
        case let .inUse(processName):
            return "正在使用：\(processName)"
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
