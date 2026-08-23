import MacToolsPluginKit
import SwiftUI

struct R2SettingsView: View {
    @ObservedObject var plugin: CloudflareR2Plugin
    @ObservedObject private var store: R2ConfigurationStore
    private let localization: PluginLocalization

    init(
        plugin: CloudflareR2Plugin,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.plugin = plugin
        store = plugin.configurationStore
        self.localization = localization
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            sectionHeader(localization.string(
                "settings.guide.section",
                defaultValue: "配置指引"
            ), icon: "questionmark.circle.fill")
            configurationGuide

            sectionHeader(localization.string(
                "settings.credentials.section",
                defaultValue: "R2 凭据"
            ), icon: "key.fill")
            VStack(spacing: 0) {
                fieldRow("Account ID", text: $store.accountID, prompt: "Cloudflare Account ID")
                PluginSettingsListDivider()
                fieldRow(
                    "Bucket",
                    text: $store.bucket,
                    prompt: localization.string(
                        "settings.credentials.bucket.placeholder",
                        defaultValue: "Bucket 名称"
                    )
                )
                PluginSettingsListDivider()
                fieldRow("Access Key ID", text: $store.accessKeyID, prompt: "R2 API Token Access Key ID")
                PluginSettingsListDivider()
                secureFieldRow
            }
            .pluginSettingsCardBackground(.standard)

            sectionHeader(localization.string(
                "settings.options.section",
                defaultValue: "上传选项"
            ), icon: "slider.horizontal.3")
            VStack(spacing: 0) {
                fieldRow(
                    localization.string(
                        "settings.options.objectPrefix",
                        defaultValue: "对象前缀"
                    ),
                    text: $store.objectPrefix,
                    prompt: localization.string(
                        "settings.options.objectPrefix.placeholder",
                        defaultValue: "例如 uploads/2026（可选）"
                    )
                )
                if let validation = store.objectPrefixValidationMessage {
                    Text(validation)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                        .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
                }
                PluginSettingsListDivider()
                fieldRow(
                    localization.string(
                        "settings.options.publicURL",
                        defaultValue: "公开访问地址"
                    ),
                    text: $store.publicBaseURL,
                    prompt: localization.string(
                        "settings.options.publicURL.placeholder",
                        defaultValue: "https://cdn.example.com（可选）"
                    )
                )
                if let validation = store.publicBaseURLValidationMessage {
                    Text(validation)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                        .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
                }
            }
            .pluginSettingsCardBackground(.standard)

            if let message = store.errorMessage {
                Text(message).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
            }

            HStack {
                Text(localization.string(
                    "settings.secret.keychainNotice",
                    defaultValue: "Secret Access Key 仅保存在 macOS 钥匙串中。"
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(localization.string(
                    "settings.action.save",
                    defaultValue: "保存配置"
                )) { store.save() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if plugin.status.isUploading {
                    Button(localization.string(
                        "common.cancelUpload",
                        defaultValue: "取消上传"
                    )) { plugin.cancelUpload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button(localization.string(
                        "shortcut.upload.title",
                        defaultValue: "选择文件并上传"
                    )) { plugin.chooseAndUpload() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    private var configurationGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(
                "1",
                title: localization.string(
                    "settings.guide.bucket.title",
                    defaultValue: "创建或选择 Bucket"
                ),
                detail: localization.string(
                    "settings.guide.bucket.detail",
                    defaultValue: "Cloudflare 控制台 → R2 对象存储；Bucket 名称来自存储桶列表，Account ID 位于 R2 概览的账户信息中。"
                )
            )
            guideRow(
                "2",
                title: localization.string(
                    "settings.guide.credentials.title",
                    defaultValue: "创建 S3 API 凭据"
                ),
                detail: localization.string(
                    "settings.guide.credentials.detail",
                    defaultValue: "R2 概览 → 账户详情，在 API Token 旁点“管理”。创建账户或用户 API Token，并选择“对象读和写”。创建后复制 Access Key ID 和 Secret Access Key；Secret 仅显示一次。"
                )
            )
            guideRow(
                "3",
                title: localization.string(
                    "settings.guide.publicURL.title",
                    defaultValue: "配置公开访问地址（可选）"
                ),
                detail: localization.string(
                    "settings.guide.publicURL.detail",
                    defaultValue: "Bucket → 设置 → 自定义域，或启用 r2.dev 开发地址；填写包含 https:// 的根地址。"
                )
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    dashboardLink
                    credentialsDocumentationLink
                    publicAccessDocumentationLink
                }
                VStack(alignment: .leading, spacing: 6) {
                    dashboardLink
                    credentialsDocumentationLink
                    publicAccessDocumentationLink
                }
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.standard)
    }

    private var dashboardLink: some View {
        Link(
            localization.string(
                "settings.guide.openDashboard",
                defaultValue: "打开 R2 控制台"
            ),
            destination: URL(string: "https://dash.cloudflare.com/?to=/:account/r2")!
        )
    }

    private var credentialsDocumentationLink: some View {
        Link(
            localization.string(
                "settings.guide.credentialsDocs",
                defaultValue: "查看凭据文档"
            ),
            destination: URL(string: "https://developers.cloudflare.com/r2/api/tokens/")!
        )
    }

    private var publicAccessDocumentationLink: some View {
        Link(
            localization.string(
                "settings.guide.publicAccessDocs",
                defaultValue: "查看公开访问文档"
            ),
            destination: URL(string: "https://developers.cloudflare.com/r2/buckets/public-buckets/")!
        )
    }

    private func guideRow(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(detail)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var secureFieldRow: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text("Secret Access Key").font(PluginSettingsTheme.Typography.rowTitle)
                Text(store.hasStoredSecret
                    ? localization.string(
                        "settings.secret.saved",
                        defaultValue: "已保存；留空不会覆盖"
                    )
                    : localization.string(
                        "settings.secret.notSaved",
                        defaultValue: "尚未保存"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SecureField(localization.string(
                "settings.secret.placeholder",
                defaultValue: "输入 Secret Access Key"
            ), text: $store.secretAccessKey)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func fieldRow(_ title: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(title).font(PluginSettingsTheme.Typography.rowTitle)
            Spacer()
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }
}
