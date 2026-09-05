import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

private enum MenuBarIconSettingsMetrics {
    static let galleryColumnWidth: CGFloat = 128
    static let galleryColumnSpacing: CGFloat = 10
    static let galleryColumnCount = 4
    static let galleryContentWidth: CGFloat = 554
    static let galleryContentHeight: CGFloat = 340
    static let galleryPopoverWidth: CGFloat = 582
    static let galleryPreviewHeight: CGFloat = 34
    static let galleryPreviewMaxWidth: CGFloat = 122
    static let galleryTileSize = CGSize(width: 128, height: 52)
    static let galleryCellSize = CGSize(width: 128, height: 82)
    static let galleryTitleWidth: CGFloat = 120
}

private enum MenuBarIconAction: CaseIterable, Hashable {
    case upload
    case gallery

    var title: String {
        switch self {
        case .upload:
            return AppL10n.settings("menuBarIcon.upload", defaultValue: "上传")
        case .gallery:
            return AppL10n.settings("menuBarIcon.gallery.title", defaultValue: "在线图库")
        }
    }

    var systemImage: String {
        switch self {
        case .upload:
            return "square.and.arrow.up"
        case .gallery:
            return "sparkles"
        }
    }
}

private struct MenuBarIconActionLabel: View {
    let action: MenuBarIconAction

    var body: some View {
        ZStack {
            ForEach(MenuBarIconAction.allCases, id: \.self) { candidate in
                Label(
                    candidate.title,
                    systemImage: PluginSystemImage.resolvedName(candidate.systemImage)
                )
                    .lineLimit(1)
                    .opacity(candidate == action ? 1 : 0)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
    }
}

struct MenuBarIconSettingsView: View {
    @ObservedObject var iconSettings: MenuBarIconSettings
    @ObservedObject var gallery: MenuBarIconGalleryLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            MenuBarIconEditorControls(iconSettings: iconSettings, gallery: gallery)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
    }

    private var header: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "menubar.rectangle")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(AppL10n.settings("menuBarIcon.title", defaultValue: "菜单栏图标"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.settings(
                    "menuBarIcon.description",
                    defaultValue: "统一设置浅色和深色菜单栏图标，导入时会保留原图。"
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                iconSettings.resetToDefault()
            } label: {
                Label(AppL10n.settings("menuBarIcon.restoreDefault", defaultValue: "恢复默认"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!iconSettings.hasCustomIcon)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .help(AppL10n.settings("menuBarIcon.help", defaultValue: "设置菜单栏图标"))
    }
}

private struct MenuBarIconEditorControls: View {
    @ObservedObject var iconSettings: MenuBarIconSettings
    @ObservedObject var gallery: MenuBarIconGalleryLibrary

    private let rowLabelWidth: CGFloat = 76
    private let contentMaxWidth: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlRow(AppL10n.settings("menuBarIcon.source", defaultValue: "图标来源")) {
                actionButtons
            }

            contentOnlyRow {
                Text(AppL10n.settings(
                    "menuBarIcon.sourceDescription",
                    defaultValue: "支持图片、轻量 GIF/MP4 和在线动态图标；导入时会保留原图。"
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: contentMaxWidth, alignment: .leading)
            }

            if let errorMessage = iconSettings.lastErrorMessage {
                contentOnlyRow {
                    Label(errorMessage, systemImage: "xmark.circle")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func controlRow<Content: View>(
        _ title: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title)
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .foregroundStyle(.secondary)
                .frame(width: rowLabelWidth, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contentOnlyRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Color.clear
                .frame(width: rowLabelWidth, height: 1)

            content()
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtons: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            currentIconPreview

            Divider()
                .frame(height: PluginSettingsTheme.Size.rowIcon)

            Button {
                selectMedia()
            } label: {
                MenuBarIconActionLabel(action: .upload)
            }
            .buttonStyle(.borderedProminent)

            MenuBarIconGalleryPicker(iconSettings: iconSettings, gallery: gallery)
        }
        .frame(
            maxWidth: contentMaxWidth,
            minHeight: PluginSettingsTheme.Size.controlHeight,
            alignment: .trailing
        )
        .controlSize(.regular)
    }

    private var currentIconPreview: some View {
        MenuBarIconThumbnail(
            image: iconSettings.previewImage(for: .light),
            height: PluginSettingsTheme.Size.rowIcon,
            maxWidth: 26
        )
        .frame(width: 34, height: PluginSettingsTheme.Size.controlHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .help(AppL10n.settings("menuBarIcon.title", defaultValue: "菜单栏图标"))
        .accessibilityLabel(AppL10n.settings("menuBarIcon.title", defaultValue: "菜单栏图标"))
    }

    private func selectMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MenuBarIconProcessing.supportedImageContentTypes
            + MenuBarIconProcessing.supportedAnimationContentTypes
        panel.message = AppL10n.settings(
            "menuBarIcon.openPanel.message",
            defaultValue: "选择图片、GIF 或 MP4 作为 MacTools 状态栏图标"
        )

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let contentType = UTType(filenameExtension: url.pathExtension)
        if let contentType,
           MenuBarIconProcessing.supportedAnimationContentTypes.contains(where: { contentType.conforms(to: $0) }) {
            Task {
                await iconSettings.importAnimation(from: url)
            }
        } else {
            iconSettings.importIcon(from: url)
        }
    }
}

private struct MenuBarIconGalleryPicker: View {
    @ObservedObject var iconSettings: MenuBarIconSettings
    @ObservedObject var gallery: MenuBarIconGalleryLibrary
    @State private var selectedCategoryID: String?
    @State private var isPickerPresented = false
    @State private var activeAssetID: String?

    private var selectedCategory: String? {
        selectedCategoryID ?? gallery.categories.first?.id
    }

    private var filteredAssets: [MenuBarIconGalleryAsset] {
        guard let selectedCategory else {
            return []
        }

        return gallery.assets.filter { asset in
            asset.categoryID == selectedCategory
        }
    }

    var body: some View {
        Button {
            isPickerPresented.toggle()
        } label: {
            MenuBarIconActionLabel(action: .gallery)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            pickerContent
                .task {
                    await gallery.loadCatalogIfNeeded()
                    if selectedCategoryID == nil {
                        selectedCategoryID = gallery.categories.first?.id
                    }
                }
        }
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(AppL10n.settings("menuBarIcon.gallery.title", defaultValue: "在线图库"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Spacer()

                if gallery.status.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                }

                Button {
                    Task {
                        await gallery.refreshCatalog()
                        selectedCategoryID = selectedCategoryID ?? gallery.categories.first?.id
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(AppL10n.settings("menuBarIcon.gallery.refresh", defaultValue: "刷新图库"))
                .disabled(gallery.status.isLoading)

                Picker(AppL10n.settings("menuBarIcon.gallery.category", defaultValue: "分组"), selection: Binding(
                    get: { selectedCategoryID ?? gallery.categories.first?.id ?? "" },
                    set: { selectedCategoryID = $0 }
                )) {
                    ForEach(gallery.categories) { category in
                        Text(category.title).tag(category.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
                .disabled(gallery.categories.isEmpty)
            }

            content
        }
        .padding(14)
        .frame(width: MenuBarIconSettingsMetrics.galleryPopoverWidth)
    }

    @ViewBuilder
    private var content: some View {
        if gallery.status.isLoading && gallery.assets.isEmpty {
            ProgressView()
                .frame(
                    width: MenuBarIconSettingsMetrics.galleryContentWidth,
                    height: MenuBarIconSettingsMetrics.galleryContentHeight
                )
        } else if gallery.assets.isEmpty {
            ContentUnavailableView(
                AppL10n.settings("menuBarIcon.gallery.unavailable", defaultValue: "图库不可用"),
                systemImage: "wifi.exclamationmark",
                description: Text(gallery.lastErrorMessage ?? AppL10n.settings("menuBarIcon.gallery.tryLater", defaultValue: "稍后再试。"))
            )
            .frame(
                width: MenuBarIconSettingsMetrics.galleryContentWidth,
                height: MenuBarIconSettingsMetrics.galleryContentHeight
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .fixed(MenuBarIconSettingsMetrics.galleryColumnWidth),
                            spacing: MenuBarIconSettingsMetrics.galleryColumnSpacing
                        ),
                        count: MenuBarIconSettingsMetrics.galleryColumnCount
                    ),
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(filteredAssets) { asset in
                        Button {
                            Task {
                                activeAssetID = asset.id
                                let didSelect = await gallery.selectAsset(asset, iconSettings: iconSettings)
                                activeAssetID = nil
                                if didSelect {
                                    isPickerPresented = false
                                }
                            }
                        } label: {
                            MenuBarIconGalleryAssetCell(
                                asset: asset,
                                state: gallery.state(for: asset),
                                previewImage: gallery.previewImage(for: asset),
                                isBusy: activeAssetID == asset.id,
                                isSelected: iconSettings.selectedRemoteAsset?.id == asset.id
                                    && iconSettings.selectedRemoteAsset?.version == asset.version
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(activeAssetID != nil)
                        .help(AppL10n.settingsFormat("menuBarIcon.gallery.useAssetFormat", defaultValue: "使用 %@", asset.title))
                        .task {
                            await gallery.loadPreviewIfNeeded(for: asset)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(
                width: MenuBarIconSettingsMetrics.galleryContentWidth,
                height: MenuBarIconSettingsMetrics.galleryContentHeight
            )
        }
    }
}

private struct MenuBarIconGalleryAssetCell: View {
    let asset: MenuBarIconGalleryAsset
    let state: MenuBarIconGalleryAssetState
    let previewImage: NSImage?
    let isBusy: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            preview
                .frame(
                    width: MenuBarIconSettingsMetrics.galleryTileSize.width,
                    height: MenuBarIconSettingsMetrics.galleryTileSize.height
                )
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    stateBadge
                        .padding(5)
                }
                .overlay(alignment: .bottomTrailing) {
                    if asset.isAnimated {
                        animatedBadge
                            .padding(4)
                    }
                }

            Text(asset.title)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: MenuBarIconSettingsMetrics.galleryTitleWidth)
        }
        .frame(
            width: MenuBarIconSettingsMetrics.galleryCellSize.width,
            height: MenuBarIconSettingsMetrics.galleryCellSize.height
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            MenuBarIconThumbnail(
                image: previewImage,
                height: MenuBarIconSettingsMetrics.galleryPreviewHeight,
                maxWidth: MenuBarIconSettingsMetrics.galleryPreviewMaxWidth
            )
        } else {
            MenuBarIconThumbnail(
                image: nil,
                height: MenuBarIconSettingsMetrics.galleryPreviewHeight,
                maxWidth: MenuBarIconSettingsMetrics.galleryPreviewMaxWidth
            )
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(Circle())
        } else {
            switch state {
            case .cached:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(Circle())
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.orange)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(Circle())
            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(Circle())
            case .available:
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(Circle())
            }
        }
    }

    private var animatedBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Color.black.opacity(0.68), in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
            .accessibilityLabel(AppL10n.settings("menuBarIcon.gallery.animated", defaultValue: "动态"))
    }

    private var borderColor: Color {
        isSelected ? .accentColor : Color.primary.opacity(0.1)
    }
}

private struct MenuBarIconThumbnail: View {
    let image: NSImage?
    let height: CGFloat
    let maxWidth: CGFloat?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(image.isTemplate ? .template : .original)
                    .foregroundStyle(.primary)
                    .scaledToFit()
                    .frame(height: height)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: height, height: height)
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: height)
    }
}
