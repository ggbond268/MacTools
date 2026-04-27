import Foundation

enum DiskCleanDynamicRule: String, Equatable, Sendable {
    case xcodeDerivedData
    case unavailableSimulators
    case npmCache
    case pnpmStore
    case bunCache
    case pipCache
    case goBuildCache
    case goModuleCache
    case miseCache
    case jetbrainsToolboxOldVersions
    case aiAgentOldVersions
    case serviceWorkerCache
    case oldBrowserVersions
}

struct DiskCleanRule: Identifiable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case path(String)
        case dynamic(DiskCleanDynamicRule)
    }

    let id: String
    let choice: DiskCleanChoice
    let title: String
    let risk: DiskCleanRisk
    let targets: [Target]
    let skipWhenProcessIsRunning: [String]
    let requiresAdmin: Bool

    init(
        id: String,
        choice: DiskCleanChoice,
        title: String,
        risk: DiskCleanRisk,
        targets: [Target],
        skipWhenProcessIsRunning: [String] = [],
        requiresAdmin: Bool = false
    ) {
        self.id = id
        self.choice = choice
        self.title = title
        self.risk = risk
        self.targets = targets
        self.skipWhenProcessIsRunning = skipWhenProcessIsRunning
        self.requiresAdmin = requiresAdmin
    }
}

struct DiskCleanRuleCatalog: Equatable, Sendable {
    let rules: [DiskCleanRule]

    static let moleFirstVersion = DiskCleanRuleCatalog(
        rules: cacheRules + developerRules + browserRules
    )

    func rules(for choice: DiskCleanChoice) -> [DiskCleanRule] {
        rules.filter { $0.choice == choice }
    }

    private static let cacheRules: [DiskCleanRule] = [
        rule(
            id: "cache.user-essentials",
            choice: .cache,
            title: "User caches and logs",
            targets: [
                "~/Library/Caches/*",
                "~/Library/Logs/*"
            ]
        ),
        rule(
            id: "cache.macos-app-state",
            choice: .cache,
            title: "macOS app state caches",
            targets: [
                "~/Library/Saved Application State/*",
                "~/Library/Caches/com.apple.photoanalysisd",
                "~/Library/Caches/com.apple.akd",
                "~/Library/Caches/com.apple.WebKit.Networking/*",
                "~/Library/DiagnosticReports/*",
                "~/Library/Caches/com.apple.QuickLook.thumbnailcache",
                "~/Library/Caches/Quick Look/*",
                "~/Library/Caches/com.apple.iconservices*",
                "~/Library/Autosave Information/*",
                "~/Library/IdentityCaches/*",
                "~/Library/Suggestions/*",
                "~/Library/Calendars/Calendar Cache",
                "~/Library/Application Support/AddressBook/Sources/*/Photos.cache"
            ]
        ),
        rule(
            id: "cache.apple-sandboxed-apps",
            choice: .cache,
            title: "Apple sandboxed app caches",
            targets: [
                "~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.mediaanalysisd/Data/tmp/*",
                "~/Library/Containers/com.apple.AppStore/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp/*",
                "~/Library/Containers/com.apple.wallpaper.extension.aerials/Data/tmp/*",
                "~/Library/Containers/com.apple.geod/Data/tmp/*",
                "~/Library/Containers/com.apple.stocks/Data/Library/Caches/*",
                "~/Library/Application Support/com.apple.wallpaper/aerials/thumbnails/*",
                "~/Library/Caches/com.apple.helpd/*",
                "~/Library/Caches/GeoServices/*",
                "~/Library/Containers/com.apple.AvatarUI.AvatarPickerMemojiPicker/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.AMPArtworkAgent/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.NeptuneOneExtension/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.AppleMediaServicesUI.UtilityExtension/Data/tmp/*",
                "~/Library/Group Containers/group.com.apple.contentdelivery/Logs/*",
                "~/Library/Group Containers/group.com.apple.contentdelivery/Library/Logs/*"
            ]
        ),
        rule(
            id: "cache.cloud-storage",
            choice: .cache,
            title: "Cloud storage caches",
            targets: [
                "~/Library/Caches/com.dropbox.*",
                "~/Library/Caches/com.getdropbox.dropbox",
                "~/Library/Caches/com.google.GoogleDrive",
                "~/Library/Caches/com.baidu.netdisk",
                "~/Library/Caches/com.alibaba.teambitiondisk",
                "~/Library/Caches/com.box.desktop",
                "~/Library/Caches/com.microsoft.OneDrive"
            ]
        ),
        rule(
            id: "cache.office-apps",
            choice: .cache,
            title: "Office and mail app caches",
            targets: [
                "~/Library/Caches/com.microsoft.Word",
                "~/Library/Containers/com.microsoft.Word/Data/Library/Caches/*",
                "~/Library/Containers/com.microsoft.Word/Data/tmp/*",
                "~/Library/Containers/com.microsoft.Word/Data/Library/Logs/*",
                "~/Library/Caches/com.microsoft.Excel",
                "~/Library/Containers/com.microsoft.Excel/Data/Library/Caches/*",
                "~/Library/Containers/com.microsoft.Excel/Data/tmp/*",
                "~/Library/Containers/com.microsoft.Excel/Data/Library/Logs/*",
                "~/Library/Caches/com.microsoft.Powerpoint",
                "~/Library/Caches/com.microsoft.Outlook/*",
                "~/Library/Caches/com.apple.iWork.*",
                "~/Library/Caches/com.kingsoft.wpsoffice.mac",
                "~/Library/Caches/org.mozilla.thunderbird/*",
                "~/Library/Caches/com.apple.mail/*"
            ]
        ),
        rule(
            id: "cache.virtualization",
            choice: .cache,
            title: "Virtualization caches",
            targets: [
                "~/Library/Caches/com.vmware.fusion",
                "~/Library/Caches/com.parallels.*",
                "~/VirtualBox VMs/.cache",
                "~/.vagrant.d/tmp/*"
            ]
        ),
        rule(
            id: "cache.communication",
            choice: .cache,
            title: "Communication app caches",
            targets: [
                "~/Library/Application Support/discord/Cache/*",
                "~/Library/Application Support/legcord/Cache/*",
                "~/Library/Application Support/Slack/Cache/*",
                "~/Library/Caches/us.zoom.xos/*",
                "~/Library/Caches/com.tencent.xinWeChat/*",
                "~/Library/Caches/ru.keepcoder.Telegram/*",
                "~/Library/Caches/com.microsoft.teams2/*",
                "~/Library/Caches/net.whatsapp.WhatsApp/*",
                "~/Library/Caches/com.skype.skype/*",
                "~/Library/Caches/com.tencent.meeting/*",
                "~/Library/Caches/com.tencent.WeWorkMac/*",
                "~/Library/Caches/com.feishu.*/*",
                "~/Library/Application Support/Microsoft/Teams/Cache/*",
                "~/Library/Application Support/Microsoft/Teams/Application Cache/*",
                "~/Library/Application Support/Microsoft/Teams/Code Cache/*",
                "~/Library/Application Support/Microsoft/Teams/GPUCache/*",
                "~/Library/Application Support/Microsoft/Teams/logs/*",
                "~/Library/Application Support/Microsoft/Teams/tmp/*"
            ]
        ),
        rule(
            id: "cache.ai-assistants",
            choice: .cache,
            title: "AI assistant app caches",
            targets: [
                "~/Library/Caches/com.openai.chat/*",
                "~/Library/Caches/com.anthropic.claudefordesktop/*",
                "~/Library/Logs/Claude/*",
                "~/Library/Logs/com.openai.codex/*",
                "~/Library/Application Support/Codex/Cache/*",
                "~/Library/Application Support/Codex/Code Cache/*",
                "~/Library/Application Support/Codex/GPUCache/*",
                "~/Library/Application Support/Codex/DawnGraphiteCache/*",
                "~/Library/Application Support/Codex/DawnWebGPUCache/*"
            ]
        ),
        rule(
            id: "cache.creative-tools",
            choice: .cache,
            title: "Creative tool caches",
            targets: [
                "~/Library/Caches/com.bohemiancoding.sketch3/*",
                "~/Library/Application Support/com.bohemiancoding.sketch3/cache/*",
                "~/Library/Caches/Adobe/*",
                "~/Library/Caches/com.adobe.*/*",
                "~/Library/Caches/com.figma.Desktop/*",
                "~/Library/Application Support/Adobe/Common/Media Cache Files/*",
                "~/Library/Caches/net.telestream.screenflow10/*",
                "~/Library/Caches/com.apple.FinalCut/*",
                "~/Library/Caches/com.blackmagic-design.DaVinciResolve/*",
                "~/Movies/CacheClip/*",
                "~/Library/Caches/com.adobe.PremierePro.*/*",
                "~/Library/Caches/org.blenderfoundation.blender/*",
                "~/Library/Caches/com.maxon.cinema4d/*",
                "~/Library/Caches/com.autodesk.*/*",
                "~/Library/Caches/com.sketchup.*/*"
            ]
        ),
        rule(
            id: "cache.productivity-media",
            choice: .cache,
            title: "Productivity and media caches",
            targets: [
                "~/Library/Caches/com.tw93.MiaoYan/*",
                "~/Library/Caches/com.klee.desktop/*",
                "~/Library/Caches/klee_desktop/*",
                "~/Library/Caches/com.orabrowser.app/*",
                "~/Library/Caches/com.filo.client/*",
                "~/Library/Caches/com.flomoapp.mac/*",
                "~/Library/Application Support/Quark/Cache/videoCache/*",
                "~/Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Caches/*",
                "~/Library/Containers/com.ideasoncanvas.mindnode/Data/Library/Caches/*",
                "~/.cache/kaku/*",
                "~/Library/Caches/com.spotify.client/*",
                "~/Library/Caches/com.apple.Music",
                "~/Library/Caches/com.apple.podcasts",
                "~/Library/Containers/com.apple.podcasts/Data/tmp/StreamedMedia",
                "~/Library/Containers/com.apple.podcasts/Data/tmp/*.heic",
                "~/Library/Containers/com.apple.podcasts/Data/tmp/*.img",
                "~/Library/Containers/com.apple.podcasts/Data/tmp/*CFNetworkDownload*.tmp",
                "~/Library/Caches/com.apple.TV/*",
                "~/Library/Caches/tv.plex.player.desktop",
                "~/Library/Caches/com.netease.163music",
                "~/Library/Caches/com.tencent.QQMusic/*",
                "~/Library/Caches/com.kugou.mac/*",
                "~/Library/Caches/com.kuwo.mac/*",
                "~/Library/Caches/com.colliderli.iina",
                "~/Library/Caches/org.videolan.vlc",
                "~/Library/Caches/io.mpv",
                "~/Library/Caches/com.iqiyi.player",
                "~/Library/Caches/com.tencent.tenvideo",
                "~/Library/Caches/tv.danmaku.bili/*",
                "~/Library/Caches/com.douyu.*/*",
                "~/Library/Caches/com.huya.*/*",
                "~/Library/Caches/smart.stremio*/*",
                "~/Library/Application Support/stremio/stremio-server/stremio-cache/*"
            ]
        ),
        rule(
            id: "cache.utilities",
            choice: .cache,
            title: "Utility app caches",
            targets: [
                "~/Library/Caches/net.xmac.aria2gui",
                "~/Library/Caches/org.m0k.transmission",
                "~/Library/Caches/com.qbittorrent.qBittorrent",
                "~/Library/Caches/com.downie.Downie-*",
                "~/Library/Caches/com.folx.*/*",
                "~/Library/Caches/com.charlessoft.pacifist/*",
                "~/Library/Caches/com.youdao.YoudaoDict",
                "~/Library/Caches/com.eudic.*",
                "~/Library/Caches/com.bob-build.Bob",
                "~/Library/Caches/com.cleanshot.*",
                "~/Library/Caches/com.reincubate.camo",
                "~/Library/Caches/com.xnipapp.xnip",
                "~/Library/Caches/com.readdle.smartemail-Mac",
                "~/Library/Caches/com.airmail.*",
                "~/Library/Caches/com.todoist.mac.Todoist",
                "~/Library/Caches/com.any.do.*",
                "~/.zcompdump*",
                "~/.lesshst",
                "~/.viminfo.tmp",
                "~/.wget-hsts",
                "~/.cacher/logs/*",
                "~/.kite/logs/*",
                "~/Library/Caches/dev.warp.Warp-Stable/*",
                "~/Library/Logs/warp.log",
                "~/Library/Caches/SentryCrash/Warp/*",
                "~/Library/Caches/com.mitchellh.ghostty/*"
            ]
        ),
        rule(
            id: "cache.games-notes-remote",
            choice: .cache,
            title: "Games, notes, and remote desktop caches",
            targets: [
                "~/Library/Caches/com.valvesoftware.steam/*",
                "~/Library/Application Support/Steam/htmlcache/*",
                "~/Library/Application Support/Steam/appcache/*",
                "~/Library/Application Support/Steam/depotcache/*",
                "~/Library/Application Support/Steam/steamapps/shadercache/*",
                "~/Library/Application Support/Steam/logs/*",
                "~/Library/Caches/com.epicgames.EpicGamesLauncher/*",
                "~/Library/Caches/com.blizzard.Battle.net/*",
                "~/Library/Application Support/Battle.net/Cache/*",
                "~/Library/Caches/com.ea.*/*",
                "~/Library/Caches/com.gog.galaxy/*",
                "~/Library/Caches/com.riotgames.*/*",
                "~/Library/Application Support/minecraft/logs/*",
                "~/Library/Application Support/minecraft/crash-reports/*",
                "~/Library/Application Support/minecraft/webcache/*",
                "~/Library/Application Support/minecraft/webcache2/*",
                "~/.lunarclient/game-cache/*",
                "~/.lunarclient/launcher-cache/*",
                "~/.lunarclient/logs/*",
                "~/.lunarclient/offline/*/logs/*",
                "~/.lunarclient/offline/files/*/logs/*",
                "~/Library/Caches/net.pcsx2.PCSX2/*",
                "~/Library/Application Support/PCSX2/cache/*",
                "~/Library/Logs/PCSX2/*",
                "~/Library/Caches/net.rpcs3.rpcs3/*",
                "~/Library/Application Support/rpcs3/logs/*",
                "~/Library/Caches/notion.id/*",
                "~/Library/Caches/md.obsidian/*",
                "~/Library/Caches/com.logseq.*/*",
                "~/Library/Caches/com.bear-writer.*/*",
                "~/Library/Caches/com.evernote.*/*",
                "~/Library/Caches/com.yinxiang.*/*",
                "~/Library/Caches/com.teamviewer.*/*",
                "~/Library/Caches/com.anydesk.*/*",
                "~/Library/Caches/com.todesk.*/*",
                "~/Library/Caches/com.sunlogin.*/*"
            ]
        ),
        rule(
            id: "cache.launchers-system-utils",
            choice: .cache,
            title: "Launchers and system utility caches",
            targets: [
                "~/Library/Caches/com.runningwithcrayons.Alfred/*",
                "~/Library/Caches/cx.c3.theunarchiver/*",
                "~/Library/Caches/com.raycast.macos/urlcache/*",
                "~/Library/Caches/com.raycast.macos/fsCachedData/*",
                "~/Library/Caches/com.runjuu.Input-Source-Pro/*",
                "~/Library/Caches/macos-wakatime.WakaTime/*",
                "~/Library/Application Support/WeType/com.onevcat.Kingfisher.ImageCache.WeType/*",
                "~/Library/Application Support/WeType/DictUpdate/*",
                "~/Library/Application Support/mihomo-party/Cache/*",
                "~/Library/Application Support/mihomo-party/Code Cache/*",
                "~/Library/Application Support/mihomo-party/GPUCache/*",
                "~/Library/Application Support/mihomo-party/DawnGraphiteCache/*",
                "~/Library/Application Support/mihomo-party/DawnWebGPUCache/*",
                "~/Library/Application Support/mihomo-party/logs/*",
                "~/Library/Caches/ws.stash.app.mac/*"
            ]
        )
    ]

    private static let developerRules: [DiskCleanRule] = [
        DiskCleanRule(
            id: "developer.xcode-derived-data",
            choice: .developer,
            title: "Xcode DerivedData",
            risk: .medium,
            targets: [.dynamic(.xcodeDerivedData)],
            skipWhenProcessIsRunning: ["Xcode"]
        ),
        rule(
            id: "developer.xcode-user-caches",
            choice: .developer,
            title: "Xcode user caches",
            risk: .medium,
            targets: [
                "~/Library/Caches/com.apple.dt.Xcode/*",
                "~/Library/Developer/Xcode/iOS Device Logs/*",
                "~/Library/Developer/Xcode/watchOS Device Logs/*",
                "~/Library/Developer/Xcode/Products/*",
                "~/Library/Developer/Xcode/Archives/*",
                "~/Library/Developer/Xcode/DocumentationCache/*",
                "~/Library/Developer/Xcode/DocumentationIndex/*",
                "~/Library/Developer/Xcode/UserData/IB Support/*",
                "~/Library/Developer/Xcode/iOS DeviceSupport/*/Symbols/System/Library/Caches/*",
                "~/Library/Developer/Xcode/iOS DeviceSupport/*.log",
                "~/Library/Developer/Xcode/watchOS DeviceSupport/*/Symbols/System/Library/Caches/*",
                "~/Library/Developer/Xcode/watchOS DeviceSupport/*.log",
                "~/Library/Developer/Xcode/tvOS DeviceSupport/*/Symbols/System/Library/Caches/*",
                "~/Library/Developer/Xcode/tvOS DeviceSupport/*.log"
            ],
            skipWhenProcessIsRunning: ["Xcode"]
        ),
        DiskCleanRule(
            id: "developer.simulator-unavailable",
            choice: .developer,
            title: "Unavailable simulators",
            risk: .medium,
            targets: [.dynamic(.unavailableSimulators)],
            skipWhenProcessIsRunning: ["Simulator"]
        ),
        rule(
            id: "developer.simulator-caches",
            choice: .developer,
            title: "Simulator caches",
            risk: .medium,
            targets: [
                "~/Library/Developer/CoreSimulator/Caches/*",
                "~/Library/Developer/CoreSimulator/Devices/*/data/tmp/*",
                "~/Library/Logs/CoreSimulator/*",
                "~/Library/Developer/CoreSimulator/Profiles/Runtimes/*/Contents/Resources/RuntimeRoot/System/Library/Caches/*"
            ],
            skipWhenProcessIsRunning: ["Simulator"]
        ),
        DiskCleanRule(
            id: "developer.package-manager-dynamic-caches",
            choice: .developer,
            title: "Package manager dynamic caches",
            risk: .medium,
            targets: [
                .dynamic(.npmCache),
                .dynamic(.pnpmStore),
                .dynamic(.bunCache),
                .dynamic(.pipCache),
                .dynamic(.goBuildCache),
                .dynamic(.goModuleCache),
                .dynamic(.miseCache)
            ]
        ),
        rule(
            id: "developer.javascript-caches",
            choice: .developer,
            title: "JavaScript tool caches",
            risk: .medium,
            targets: [
                "~/.npm/_cacache/*",
                "~/.npm/_npx/*",
                "~/.npm/_logs/*",
                "~/.npm/_prebuilds/*",
                "~/Library/pnpm/store/*",
                "~/.bun/install/cache/*",
                "~/.tnpm/_cacache/*",
                "~/.tnpm/_logs/*",
                "~/.yarn/cache/*",
                "~/Library/Caches/Yarn/*",
                "~/.cache/typescript/*",
                "~/.cache/electron/*",
                "~/.cache/node-gyp/*",
                "~/.node-gyp/*",
                "~/.turbo/cache/*",
                "~/.vite/cache/*",
                "~/.cache/vite/*",
                "~/.cache/webpack/*",
                "~/.parcel-cache/*",
                "~/.cache/eslint/*",
                "~/.cache/prettier/*"
            ]
        ),
        rule(
            id: "developer.python-caches",
            choice: .developer,
            title: "Python and ML caches",
            risk: .medium,
            targets: [
                "~/Library/Caches/pip/*",
                "~/.cache/pip/*",
                "~/.pyenv/cache/*",
                "~/.cache/poetry/*",
                "~/.cache/uv/*",
                "~/.cache/ruff/*",
                "~/.cache/mypy/*",
                "~/.pytest_cache/*",
                "~/.jupyter/runtime/*",
                "~/.cache/huggingface/*",
                "~/.cache/torch/*",
                "~/.cache/tensorflow/*",
                "~/.conda/pkgs/*",
                "~/anaconda3/pkgs/*",
                "~/.cache/wandb/*"
            ]
        ),
        rule(
            id: "developer.rust-go-docker",
            choice: .developer,
            title: "Rust, Go, and Docker caches",
            risk: .medium,
            targets: [
                "~/.cargo/registry/cache/*",
                "~/.cargo/git/*",
                "~/.rustup/downloads/*",
                "~/Library/Caches/go-build/*",
                "~/go/pkg/mod/*",
                "~/.docker/buildx/cache/*"
            ]
        ),
        rule(
            id: "developer.mobile-caches",
            choice: .developer,
            title: "Mobile development caches",
            risk: .medium,
            targets: [
                "~/Library/Caches/Google/AndroidStudio*/*",
                "~/.android/build-cache/*",
                "~/.android/cache/*",
                "~/.cache/swift-package-manager/*",
                "~/Library/Caches/org.swift.swiftpm/*",
                "~/.expo/expo-go/*",
                "~/.expo/android-apk-cache/*",
                "~/.expo/ios-simulator-app-cache/*",
                "~/.expo/native-modules-cache/*",
                "~/.expo/schema-cache/*",
                "~/.expo/template-cache/*",
                "~/.expo/versions-cache/*"
            ]
        ),
        rule(
            id: "developer.jvm-caches",
            choice: .developer,
            title: "JVM caches",
            risk: .medium,
            targets: [
                "~/.m2/repository/*",
                "~/.sbt/*",
                "~/.ivy2/cache/*",
                "~/.gradle/caches/*",
                "~/.gradle/daemon/*"
            ]
        ),
        DiskCleanRule(
            id: "developer.jetbrains-toolbox-old-versions",
            choice: .developer,
            title: "JetBrains Toolbox old IDE versions",
            risk: .medium,
            targets: [.dynamic(.jetbrainsToolboxOldVersions)]
        ),
        DiskCleanRule(
            id: "developer.ai-agent-old-versions",
            choice: .developer,
            title: "AI coding agent old versions",
            risk: .medium,
            targets: [.dynamic(.aiAgentOldVersions)]
        ),
        rule(
            id: "developer.editor-caches",
            choice: .developer,
            title: "Editor caches",
            risk: .medium,
            targets: [
                "~/Library/Application Support/Code/logs/*",
                "~/Library/Application Support/Code/Cache/*",
                "~/Library/Application Support/Code/CachedExtensions/*",
                "~/Library/Application Support/Code/CachedData/*",
                "~/Library/Application Support/Code/DawnGraphiteCache/*",
                "~/Library/Application Support/Code/DawnWebGPUCache/*",
                "~/Library/Application Support/Code/GPUCache/*",
                "~/Library/Application Support/Code/CachedExtensionVSIXs/*",
                "~/Library/Application Support/Code/Service Worker/ScriptCache/*",
                "~/Library/Caches/com.microsoft.VSCode/Cache/*",
                "~/Library/Caches/com.sublimetext.*/*",
                "~/Library/Caches/Zed/*",
                "~/Library/Logs/Zed/*",
                "~/Library/Caches/copilot/*",
                "~/.cache/vscode-ripgrep/*",
                "~/Library/Caches/Cursor/*",
                "~/Library/Application Support/Cursor/CachedData/*",
                "~/Library/Application Support/Cursor/CachedExtensionVSIXs/*",
                "~/Library/Application Support/Cursor/GPUCache/*",
                "~/Library/Application Support/Cursor/DawnGraphiteCache/*",
                "~/Library/Application Support/Cursor/DawnWebGPUCache/*",
                "~/Library/Application Support/Cursor/Service Worker/ScriptCache/*"
            ]
        ),
        rule(
            id: "developer.cloud-devops-caches",
            choice: .developer,
            title: "Cloud and DevOps caches",
            risk: .medium,
            targets: [
                "~/.kube/cache/*",
                "~/.local/share/containers/storage/tmp/*",
                "~/.aws/cli/cache/*",
                "~/.config/gcloud/logs/*",
                "~/.azure/logs/*",
                "~/.cache/terraform/*",
                "~/.grafana/cache/*",
                "~/.prometheus/data/wal/*",
                "~/.jenkins/workspace/*/target/*",
                "~/.cache/gitlab-runner/*",
                "~/.github/cache/*",
                "~/.circleci/cache/*",
                "~/.sonar/*"
            ]
        ),
        rule(
            id: "developer.language-caches",
            choice: .developer,
            title: "Other language tool caches",
            risk: .medium,
            targets: [
                "~/.bundle/cache/*",
                "~/.composer/cache/*",
                "~/Library/Caches/composer/*",
                "~/.nuget/packages/*",
                "~/.cache/bazel/*",
                "~/.cache/zig/*",
                "~/Library/Caches/deno/*",
                "~/.hex/cache/*",
                "~/.cabal/packages/*",
                "~/.opam/download-cache/*"
            ]
        ),
        rule(
            id: "developer.database-api-caches",
            choice: .developer,
            title: "Database and API tool caches",
            risk: .medium,
            targets: [
                "~/Library/Caches/com.sequel-ace.sequel-ace/*",
                "~/Library/Caches/com.eggerapps.Sequel-Pro/*",
                "~/Library/Caches/redis-desktop-manager/*",
                "~/Library/Caches/com.navicat.*",
                "~/Library/Caches/com.dbeaver.*",
                "~/Library/Caches/com.redis.RedisInsight",
                "~/Library/Caches/com.postmanlabs.mac/*",
                "~/Library/Caches/com.konghq.insomnia/*",
                "~/Library/Caches/com.tinyapp.TablePlus/*",
                "~/Library/Caches/com.getpaw.Paw/*",
                "~/Library/Caches/com.charlesproxy.charles/*",
                "~/Library/Caches/com.proxyman.NSProxy/*"
            ]
        ),
        rule(
            id: "developer.misc-caches",
            choice: .developer,
            title: "Misc developer caches",
            risk: .medium,
            targets: [
                "~/Library/Caches/com.unity3d.*/*",
                "~/Library/Caches/com.mongodb.compass/*",
                "~/Library/Caches/com.figma.Desktop/*",
                "~/Library/Caches/com.github.GitHubDesktop/*",
                "~/Library/Caches/SentryCrash/*",
                "~/Library/Caches/KSCrash/*",
                "~/Library/Caches/com.crashlytics.data/*",
                "~/Library/Application Support/Antigravity/Cache/*",
                "~/Library/Application Support/Antigravity/Code Cache/*",
                "~/Library/Application Support/Antigravity/GPUCache/*",
                "~/Library/Application Support/Antigravity/DawnGraphiteCache/*",
                "~/Library/Application Support/Antigravity/DawnWebGPUCache/*",
                "~/Library/Application Support/Codex/Cache/*",
                "~/Library/Application Support/Codex/Code Cache/*",
                "~/Library/Application Support/Codex/GPUCache/*",
                "~/Library/Application Support/Codex/DawnGraphiteCache/*",
                "~/Library/Application Support/Codex/DawnWebGPUCache/*",
                "~/Library/Application Support/Filo/production/Cache/*",
                "~/Library/Application Support/Filo/production/Code Cache/*",
                "~/Library/Application Support/Filo/production/GPUCache/*",
                "~/Library/Application Support/Filo/production/DawnGraphiteCache/*",
                "~/Library/Application Support/Filo/production/DawnWebGPUCache/*",
                "~/Library/Application Support/Claude/Cache/*",
                "~/Library/Application Support/Claude/Code Cache/*",
                "~/Library/Application Support/Claude/GPUCache/*",
                "~/Library/Application Support/Claude/DawnGraphiteCache/*",
                "~/Library/Application Support/Claude/DawnWebGPUCache/*",
                "~/Library/Application Support/Claude/sentry/*",
                "~/Library/Application Support/Claude/pending-uploads/*",
                "~/Library/Application Support/Qoder/Cache/*",
                "~/Library/Application Support/Qoder/CachedData/*",
                "~/Library/Application Support/Qoder/CachedExtensionVSIXs/*",
                "~/Library/Application Support/Qoder/Code Cache/*",
                "~/Library/Application Support/Qoder/GPUCache/*",
                "~/Library/Application Support/Qoder/DawnGraphiteCache/*",
                "~/Library/Application Support/Qoder/DawnWebGPUCache/*",
                "~/Library/Application Support/Qoder/logs/*",
                "~/.cache/prisma/*",
                "~/.cache/opencode/*"
            ]
        ),
        rule(
            id: "developer.shell-network-caches",
            choice: .developer,
            title: "Shell and network tool caches",
            risk: .low,
            targets: [
                "~/.gitconfig.lock",
                "~/.gitconfig.bak*",
                "~/.oh-my-zsh/cache/*",
                "~/.config/fish/fish_history.bak*",
                "~/.bash_history.bak*",
                "~/.zsh_history.bak*",
                "~/.cache/pre-commit/*",
                "~/.cache/curl/*",
                "~/.cache/wget/*",
                "~/Library/Caches/curl/*",
                "~/Library/Caches/wget/*"
            ]
        ),
        rule(
            id: "developer.homebrew",
            choice: .developer,
            title: "Homebrew caches",
            risk: .medium,
            targets: [
                "~/Library/Caches/Homebrew/*"
            ]
        )
    ]

    private static let browserRules: [DiskCleanRule] = [
        rule(
            id: "browser.safari",
            choice: .browser,
            title: "Safari cache",
            targets: [
                "~/Library/Caches/com.apple.Safari/*"
            ]
        ),
        rule(
            id: "browser.chrome",
            choice: .browser,
            title: "Chrome and Chromium caches",
            targets: [
                "~/Library/Caches/Google/Chrome/*",
                "~/Library/Application Support/Google/Chrome/*/Application Cache/*",
                "~/Library/Application Support/Google/Chrome/*/GPUCache/*",
                "~/Library/Application Support/Google/Chrome/component_crx_cache/*",
                "~/Library/Application Support/Google/Chrome/ShaderCache/*",
                "~/Library/Application Support/Google/Chrome/GrShaderCache/*",
                "~/Library/Application Support/Google/Chrome/GraphiteDawnCache/*",
                "~/Library/Application Support/Google/Chrome/*/Service Worker/ScriptCache/*",
                "~/Library/Application Support/Google/GoogleUpdater/crx_cache/*",
                "~/Library/Application Support/Google/GoogleUpdater/*.old",
                "~/Library/Caches/Chromium/*",
                "~/.cache/puppeteer/*"
            ],
            skipWhenProcessIsRunning: ["Google Chrome"]
        ),
        rule(
            id: "browser.edge",
            choice: .browser,
            title: "Edge cache",
            targets: [
                "~/Library/Caches/com.microsoft.edgemac/*"
            ]
        ),
        rule(
            id: "browser.arc-dia",
            choice: .browser,
            title: "Arc and Dia caches",
            targets: [
                "~/Library/Caches/company.thebrowser.Browser/*",
                "~/Library/Application Support/Arc/*/GPUCache/*",
                "~/Library/Application Support/Arc/ShaderCache/*",
                "~/Library/Application Support/Arc/GrShaderCache/*",
                "~/Library/Application Support/Arc/GraphiteDawnCache/*",
                "~/Library/Application Support/Arc/*/Service Worker/ScriptCache/*",
                "~/Library/Caches/company.thebrowser.dia/*"
            ],
            skipWhenProcessIsRunning: ["Arc"]
        ),
        rule(
            id: "browser.brave",
            choice: .browser,
            title: "Brave cache",
            targets: [
                "~/Library/Caches/BraveSoftware/Brave-Browser/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/*/Application Cache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/*/GPUCache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/component_crx_cache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/ShaderCache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/GrShaderCache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/GraphiteDawnCache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/*/Service Worker/ScriptCache/*"
            ],
            skipWhenProcessIsRunning: ["Brave Browser"]
        ),
        rule(
            id: "browser.helium-yandex",
            choice: .browser,
            title: "Helium and Yandex caches",
            targets: [
                "~/Library/Caches/net.imput.helium/*",
                "~/Library/Application Support/net.imput.helium/*/GPUCache/*",
                "~/Library/Application Support/net.imput.helium/component_crx_cache/*",
                "~/Library/Application Support/net.imput.helium/extensions_crx_cache/*",
                "~/Library/Application Support/net.imput.helium/GrShaderCache/*",
                "~/Library/Application Support/net.imput.helium/GraphiteDawnCache/*",
                "~/Library/Application Support/net.imput.helium/ShaderCache/*",
                "~/Library/Application Support/net.imput.helium/*/Application Cache/*",
                "~/Library/Caches/Yandex/YandexBrowser/*",
                "~/Library/Application Support/Yandex/YandexBrowser/ShaderCache/*",
                "~/Library/Application Support/Yandex/YandexBrowser/GrShaderCache/*",
                "~/Library/Application Support/Yandex/YandexBrowser/GraphiteDawnCache/*",
                "~/Library/Application Support/Yandex/YandexBrowser/*/GPUCache/*"
            ]
        ),
        rule(
            id: "browser.firefox",
            choice: .browser,
            title: "Firefox cache",
            targets: [
                "~/Library/Caches/Firefox/*",
                "~/Library/Application Support/Firefox/Profiles/*/cache2/*"
            ],
            skipWhenProcessIsRunning: ["Firefox"]
        ),
        rule(
            id: "browser.opera-vivaldi",
            choice: .browser,
            title: "Opera and Vivaldi caches",
            targets: [
                "~/Library/Caches/com.operasoftware.Opera/*",
                "~/Library/Caches/com.vivaldi.Vivaldi/*",
                "~/Library/Application Support/Vivaldi/*/GPUCache/*",
                "~/Library/Application Support/Vivaldi/ShaderCache/*",
                "~/Library/Application Support/Vivaldi/GrShaderCache/*",
                "~/Library/Application Support/Vivaldi/GraphiteDawnCache/*",
                "~/Library/Application Support/Vivaldi/*/Service Worker/ScriptCache/*"
            ],
            skipWhenProcessIsRunning: ["Vivaldi"]
        ),
        rule(
            id: "browser.comet-orion-zen",
            choice: .browser,
            title: "Comet, Orion, and Zen caches",
            targets: [
                "~/Library/Caches/Comet/*",
                "~/Library/Caches/com.kagi.kagimacOS/*",
                "~/Library/Caches/zen/*"
            ]
        ),
        DiskCleanRule(
            id: "browser.service-worker",
            choice: .browser,
            title: "Browser Service Worker caches",
            risk: .medium,
            targets: [.dynamic(.serviceWorkerCache)]
        ),
        DiskCleanRule(
            id: "browser.old-versions",
            choice: .browser,
            title: "Old browser versions",
            risk: .medium,
            targets: [.dynamic(.oldBrowserVersions)]
        )
    ]

    private static func rule(
        id: String,
        choice: DiskCleanChoice,
        title: String,
        risk: DiskCleanRisk = .low,
        targets: [String],
        skipWhenProcessIsRunning: [String] = [],
        requiresAdmin: Bool = false
    ) -> DiskCleanRule {
        DiskCleanRule(
            id: id,
            choice: choice,
            title: title,
            risk: risk,
            targets: targets.map { .path($0) },
            skipWhenProcessIsRunning: skipWhenProcessIsRunning,
            requiresAdmin: requiresAdmin
        )
    }
}
