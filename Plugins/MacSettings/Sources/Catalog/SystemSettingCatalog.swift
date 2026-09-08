import Foundation
import MacToolsPluginKit

@MainActor
struct SystemSettingRecord {
    let definition: SystemSettingDefinition
    let adapter: any SystemSettingAdapter

    var id: SystemSettingID { definition.id }
}

enum SystemSettingCatalogValidationError: Error, Equatable {
    case duplicateID(SystemSettingID)
    case emptyID
    case invalidSchema(SystemSettingID)
    case invalidDefaultValue(SystemSettingID)
    case missingSearchMetadata(SystemSettingID)
    case sensitivePortableValue(SystemSettingID)
}

@MainActor
struct SystemSettingCatalog {
    let records: [SystemSettingRecord]
    // Retain validation metadata without exposing deferred adapters to execution.
    let deferredDefinitions: [SystemSettingID: SystemSettingDefinition]

    init(records: [SystemSettingRecord], deferring deferredIDs: Set<SystemSettingID> = []) throws {
        var ids: Set<SystemSettingID> = []
        for record in records {
            let definition = record.definition
            guard !definition.id.rawValue.isEmpty else {
                throw SystemSettingCatalogValidationError.emptyID
            }
            guard ids.insert(definition.id).inserted else {
                throw SystemSettingCatalogValidationError.duplicateID(definition.id)
            }
            guard definition.schema.isValid else {
                throw SystemSettingCatalogValidationError.invalidSchema(definition.id)
            }
            if let defaultValue = definition.defaultValue,
               !definition.schema.accepts(defaultValue) {
                throw SystemSettingCatalogValidationError.invalidDefaultValue(definition.id)
            }
            guard !definition.title.isEmpty,
                  !definition.description.isEmpty,
                  !definition.searchTerms.isEmpty else {
                throw SystemSettingCatalogValidationError.missingSearchMetadata(definition.id)
            }
            guard !definition.isSensitive || definition.portability != .portable else {
                throw SystemSettingCatalogValidationError.sensitivePortableValue(definition.id)
            }
        }
        self.records = records.filter { !deferredIDs.contains($0.id) }
        self.deferredDefinitions = Dictionary(uniqueKeysWithValues: records
            .filter { deferredIDs.contains($0.id) }
            .map { ($0.id, $0.definition) })
    }

    subscript(id: SystemSettingID) -> SystemSettingRecord? {
        records.first { $0.id == id }
    }

    func search(_ query: String, in records: [SystemSettingRecord]? = nil) -> [SystemSettingRecord] {
        let candidates = records ?? self.records
        let tokens = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return candidates }

        return candidates.compactMap { record -> (SystemSettingRecord, Int)? in
            let definition = record.definition
            let title = definition.title.lowercased()
            let document = definition.searchDocument
            guard tokens.allSatisfy({ document.contains($0) }) else { return nil }
            let score = tokens.reduce(into: 0) { score, token in
                if title == token { score += 100 }
                else if title.hasPrefix(token) { score += 60 }
                else if title.contains(token) { score += 40 }
                else if definition.searchTerms.contains(where: { $0.lowercased() == token }) { score += 25 }
                else { score += 10 }
            }
            return (record, score)
        }
        .sorted {
            if $0.1 == $1.1 {
                return $0.0.definition.title.localizedCompare($1.0.definition.title) == .orderedAscending
            }
            return $0.1 > $1.1
        }
        .map(\.0)
    }
}

@MainActor
enum MacSettingsCatalogFactory {
    // Revisit criteria and the original 47-setting numbering are recorded in
    // docs/superpowers/specs/2026-08-28-mac-settings-catalog-review.md.
    private static let deferredSettingIDs: Set<SystemSettingID> = [
        "accessibility.full-keyboard-access",
        "accessibility.sticky-keys",
        "accessibility.slow-keys",
        "input.secondary-click",
        "keyboard.function-keys",
        "screenshots.destination",
        "display.night-shift",
    ]

    static let globalDomain = UserDefaults.globalDomain
    static let finderDomain = "com.apple.finder"
    static let dockDomain = "com.apple.dock"
    static let screenshotDomain = "com.apple.screencapture"
    static let trackpadDomain = "com.apple.AppleMultitouchTrackpad"
    static let bluetoothTrackpadDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"

    static func make(
        actionContext: @escaping () -> PluginActionExecutionHostContext?
    ) throws -> SystemSettingCatalog {
        let records: [SystemSettingRecord] = [
            direct(
                id: "accessibility.three-finger-drag",
                title: "Three-Finger Drag",
                description: "Drag windows and items with three fingers.",
                category: .accessibility,
                systemImage: "hand.draw",
                schema: .boolean,
                defaultValue: .boolean(false),
                searchTerms: ["drag window trackpad", "three finger drag", "拖动窗口", "触控板"],
                destination: accessibilityDestination("PointerControl"),
                note: "Uses the runtime-validated System Settings trackpad backend for an immediate hardware update, then verifies both built-in and Bluetooth preference domains.",
                adapter: LiveTrackpadBooleanSystemSettingAdapter(
                    threeFingerDragPersistedAdapter: CompositeBooleanSystemSettingAdapter(adapters: [
                        TrackpadBooleanPreferencesSettingAdapter(
                            domain: trackpadDomain,
                            key: "TrackpadThreeFingerDrag"
                        ),
                        TrackpadBooleanPreferencesSettingAdapter(
                            domain: bluetoothTrackpadDomain,
                            key: "TrackpadThreeFingerDrag"
                        ),
                    ])
                )
            ),
            direct(
                id: "accessibility.pointer-size",
                title: "Pointer Size",
                description: "Make the onscreen pointer easier to see.",
                category: .accessibility,
                systemImage: "cursorarrow",
                schema: .decimal(range: 1 ... 4, step: 0.1),
                defaultValue: .decimal(1),
                requirements: .init(requiredPermissionID: MacSettingsPermission.fullDiskAccess),
                searchTerms: ["large cursor", "pointer size", "大光标", "鼠标指针"],
                destination: accessibilityDestination("Display"),
                note: "Requires Full Disk Access because macOS protects the persisted Universal Access domain. After authorization and an app relaunch, MacTools persists the allowlisted cursor key, invokes Apple's live cursor rebuild, and verifies WindowServer's active scale.",
                adapter: UniversalAccessSystemSettingAdapter.cursorSize()
            ),
            direct(
                id: "accessibility.keyboard-zoom",
                title: "Use Keyboard Shortcuts to Zoom",
                description: "Zoom the screen using Option–Command shortcuts.",
                category: .accessibility,
                systemImage: "plus.magnifyingglass",
                schema: .boolean,
                defaultValue: .boolean(false),
                searchTerms: ["zoom keyboard", "keyboard shortcuts to zoom", "屏幕缩放", "放大"],
                destination: accessibilityDestination("Zoom"),
                note: "Uses Apple's live keyboard-zoom setter so the zoom shortcuts are enabled immediately.",
                adapter: UniversalAccessSystemSettingAdapter.keyboardZoom()
            ),
            direct(
                id: "accessibility.scroll-zoom",
                title: "Use Scroll Gesture to Zoom",
                description: "Hold a modifier key and scroll to zoom the screen.",
                category: .accessibility,
                systemImage: "scroll",
                schema: .boolean,
                defaultValue: .boolean(false),
                searchTerms: ["scroll gesture zoom", "modifier zoom", "滚动缩放", "修饰键缩放"],
                destination: accessibilityDestination("Zoom"),
                note: "Uses Apple's live scroll-zoom setter, which updates the active HID modifier binding immediately.",
                adapter: UniversalAccessSystemSettingAdapter.scrollZoom()
            ),
            direct(
                id: "accessibility.scroll-zoom-modifier",
                title: "Modifier Key for Scroll Gesture",
                description: "Choose the modifier key to use with the scroll gesture.",
                category: .accessibility,
                systemImage: "command",
                schema: .choice(options: [
                    .init(id: "control", title: "⌃ Control"),
                    .init(id: "option", title: "⌥ Option"),
                    .init(id: "command", title: "⌘ Command"),
                ]),
                defaultValue: .choice(id: "control"),
                searchTerms: ["scroll zoom modifier", "modifier", "control option command", "缩放修饰键", "滚动手势按键"],
                destination: accessibilityDestination("Zoom"),
                note: "Maps Apple's supported modifiers and applies the selected binding to the active HID zoom gesture immediately.",
                adapter: UniversalAccessSystemSettingAdapter.scrollZoomModifier(
                    defaultID: "control",
                    values: [
                        "control": 262_144,
                        "option": 524_288,
                        "command": 1_048_576,
                    ]
                )
            ),
            direct(
                id: "accessibility.full-keyboard-access",
                title: "Full Keyboard Access",
                description: "Use Tab and other keys to move between onscreen controls.",
                category: .accessibility,
                systemImage: "keyboard.badge.ellipsis",
                schema: .boolean,
                defaultValue: .boolean(false),
                searchTerms: ["full keyboard access", "keyboard navigation", "全键盘访问", "Tab 导航"],
                destination: accessibilityDestination("Keyboard"),
                note: "Uses Apple's active Universal Access keyboard setter and verifies the current runtime state immediately.",
                adapter: UniversalAccessSystemSettingAdapter.fullKeyboardAccess()
            ),
            direct(
                id: "accessibility.sticky-keys",
                title: "Sticky Keys",
                description: "Press modifier keys one at a time to enter key combinations.",
                category: .accessibility,
                systemImage: "command",
                schema: .boolean,
                defaultValue: .boolean(false),
                searchTerms: ["sticky keys", "modifier keys", "粘滞键", "组合键"],
                destination: accessibilityDestination("Keyboard"),
                note: "Uses Apple's active Universal Access Sticky Keys setter and verifies the current runtime state immediately.",
                adapter: UniversalAccessSystemSettingAdapter.stickyKeys()
            ),
            direct(
                id: "accessibility.slow-keys",
                title: "Slow Keys",
                description: "Adjust how long a key must be held before it is accepted.",
                category: .accessibility,
                systemImage: "timer",
                schema: .boolean,
                defaultValue: .boolean(false),
                searchTerms: ["slow keys", "acceptance delay", "慢速键", "按键延迟"],
                destination: accessibilityDestination("Keyboard"),
                note: "Uses Apple's active Universal Access Slow Keys setter and verifies the current runtime state immediately.",
                adapter: UniversalAccessSystemSettingAdapter.slowKeys()
            ),
            direct(
                id: "input.secondary-click",
                title: "Secondary Click",
                description: "Choose the trackpad gesture for a secondary click.",
                category: .input,
                systemImage: "hand.point.up.left",
                schema: .choice(options: [
                    .init(id: "off", title: "Off"),
                    .init(id: "two-fingers", title: "Click with Two Fingers"),
                    .init(id: "bottom-right", title: "Click in Bottom-Right Corner"),
                    .init(id: "bottom-left", title: "Click in Bottom-Left Corner"),
                ]),
                defaultValue: .choice(id: "two-fingers"),
                executionClass: .hardwareDependent,
                searchTerms: ["secondary click", "right click", "辅助点按", "右键"],
                destination: inputDestination,
                note: "Uses the runtime-validated System Settings trackpad backend and verifies both the two-finger flag and corner gesture immediately.",
                adapter: TrackpadSecondaryClickSystemSettingAdapter()
            ),
            direct(
                id: "input.scroll-speed",
                title: "Trackpad Scroll Speed",
                description: "Adjust how quickly content scrolls with the trackpad.",
                category: .input,
                systemImage: "scroll",
                schema: .decimal(range: 0 ... 10, step: 0.5),
                defaultValue: .decimal(5),
                executionClass: .hardwareDependent,
                searchTerms: ["trackpad scroll speed", "scroll speed", "触控板滚动速度"],
                destination: inputDestination,
                note: "Uses the runtime-validated System Settings trackpad backend and verifies its active raw scroll-speed value immediately.",
                adapter: LiveScrollSpeedSystemSettingAdapter.trackpad()
            ),
            direct(
                id: "input.mouse-scroll-speed",
                title: "Mouse Scroll Speed",
                description: "Adjust how quickly content scrolls with the mouse wheel.",
                category: .input,
                systemImage: "computermouse",
                schema: .decimal(range: 0 ... 10, step: 0.5),
                defaultValue: .decimal(5),
                executionClass: .hardwareDependent,
                searchTerms: ["mouse scroll speed", "wheel speed", "鼠标滚动速度", "滚轮速度"],
                destination: mouseDestination,
                note: "Uses the runtime-validated System Settings mouse backend and verifies its active raw scroll-speed value immediately.",
                adapter: LiveScrollSpeedSystemSettingAdapter.mouse()
            ),
            direct(
                id: "input.tap-to-click",
                title: "Tap to Click",
                description: "Tap the trackpad to click.",
                category: .input,
                systemImage: "hand.tap",
                schema: .boolean,
                defaultValue: .boolean(false),
                executionClass: .hardwareDependent,
                searchTerms: ["tap to click", "touch click", "触控板轻点"],
                destination: inputDestination,
                note: "Uses the runtime-validated System Settings trackpad backend, then verifies the active tap behavior and both preference domains.",
                adapter: LiveTrackpadBooleanSystemSettingAdapter(
                    tapToClickPersistedAdapter: CompositeBooleanSystemSettingAdapter(adapters: [
                        TrackpadBooleanPreferencesSettingAdapter(
                            domain: trackpadDomain,
                            key: "Clicking"
                        ),
                        TrackpadBooleanPreferencesSettingAdapter(
                            domain: bluetoothTrackpadDomain,
                            key: "Clicking"
                        ),
                    ])
                )
            ),
            domainBoolean(
                id: "input.natural-scrolling",
                title: "Natural Scrolling",
                description: "Move content in the direction your fingers move.",
                category: .input,
                domain: globalDomain,
                key: "com.apple.swipescrolldirection",
                defaultValue: true,
                searchTerms: ["natural scrolling", "reverse scroll", "滚动方向"],
                destination: inputDestination,
                notificationName: Notification.Name("SwipeScrollDirectionDidChangeNotification")
            ),
            defaultsDecimal(
                id: "input.mouse-tracking-speed",
                title: "Mouse Tracking Speed",
                description: "Adjust how quickly the mouse pointer moves.",
                category: .input,
                key: "com.apple.mouse.scaling",
                defaultValue: 1,
                range: 0 ... 3,
                step: 0.1,
                searchTerms: ["mouse tracking speed", "pointer speed", "鼠标速度"],
                destination: mouseDestination,
                executionClass: .directRequiresLogout
            ),
            direct(
                id: "input.trackpad-tracking-speed",
                title: "Trackpad Tracking Speed",
                description: "Adjust how quickly the pointer moves with the trackpad.",
                category: .input,
                systemImage: "slider.horizontal.3",
                schema: .decimal(range: 0 ... 3, step: 0.1),
                defaultValue: .decimal(1),
                executionClass: .hardwareDependent,
                searchTerms: ["trackpad tracking speed", "pointer speed", "触控板速度"],
                destination: inputDestination,
                note: "Uses the runtime-validated System Settings trackpad backend and verifies the active tracking speed.",
                adapter: LiveTrackpadDecimalSystemSettingAdapter(
                    persistedAdapter: DefaultsSystemSettingAdapter.decimal(
                        domain: globalDomain,
                        key: "com.apple.trackpad.scaling",
                        defaultValue: 1
                    )
                )
            ),
            defaultsInteger(
                id: "keyboard.key-repeat",
                title: "Key Repeat Rate",
                description: "Adjust how quickly characters repeat when you hold a key.",
                key: "KeyRepeat",
                defaultValue: 6,
                range: 1 ... 15,
                searchTerms: ["key repeat rate", "typing repeat", "按键连发"],
                executionClass: .directRequiresLogout
            ),
            defaultsInteger(
                id: "keyboard.initial-key-repeat",
                title: "Delay Until Repeat",
                description: "Adjust the delay before a held key starts repeating.",
                key: "InitialKeyRepeat",
                defaultValue: 25,
                range: 10 ... 120,
                searchTerms: ["delay until repeat", "key repeat delay", "重复延迟"],
                executionClass: .directRequiresLogout
            ),
            domainBoolean(
                id: "keyboard.function-keys",
                title: "Use F1, F2, etc. as Standard Function Keys",
                description: "Use function keys directly; hold Fn to use their special features.",
                category: .keyboard,
                domain: globalDomain,
                key: "com.apple.keyboard.fnState",
                defaultValue: false,
                searchTerms: ["function keys", "standard F keys", "Fn 键"],
                destination: keyboardDestination,
                notificationName: Notification.Name("com.apple.keyboard.fnstatedidchange")
            ),
            direct(
                id: "finder.show-all-extensions",
                title: "Show All Filename Extensions",
                description: "Show all filename extensions in Finder.",
                category: .finder,
                systemImage: "doc.badge.gearshape",
                schema: .boolean,
                defaultValue: .boolean(false),
                executionClass: .directRequiresRestart,
                searchTerms: ["show extension", "filename extension", "文件后缀"],
                destination: finderDestination,
                note: "Writes the global filename-extension preference and removes legacy Finder overrides. Undo restores the exact original keys, including absence. Finder may need relaunching; no filenames or per-file flags are changed.",
                adapter: FinderExtensionsSystemSettingAdapter()
            ),
            finderBoolean(
                id: "finder.warn-extension-change",
                title: "Warn Before Changing an Extension",
                description: "Ask for confirmation before changing a filename extension.",
                key: "FXEnableExtensionChangeWarning",
                defaultValue: true,
                searchTerms: ["extension warning", "change filename extension", "扩展名警告"],
                executionClass: .directAppliesNextUse
            ),
            finderBoolean(
                id: "finder.warn-empty-trash",
                title: "Warn Before Emptying the Trash",
                description: "Ask for confirmation before permanently removing items from the Trash.",
                key: "WarnOnEmptyTrash",
                defaultValue: true,
                searchTerms: ["empty trash warning", "trash confirmation", "清倒废纸篓警告"],
                executionClass: .directAppliesNextUse
            ),
            finderBoolean(
                id: "finder.folders-first",
                title: "Keep Folders on Top When Sorting by Name",
                description: "Show folders before files in Finder windows.",
                key: "_FXSortFoldersFirst",
                defaultValue: false,
                searchTerms: ["folders on top", "sort folders first", "文件夹置顶"],
                executionClass: .directRequiresRestart
            ),
            finderBoolean(
                id: "finder.show-path-bar",
                title: "Show Path Bar",
                description: "Show the current location at the bottom of Finder windows.",
                key: "ShowPathbar",
                defaultValue: false,
                searchTerms: ["finder path bar", "show path", "路径栏"],
                executionClass: .directRequiresRestart
            ),
            finderBoolean(
                id: "finder.show-status-bar",
                title: "Show Status Bar",
                description: "Show item counts and available space at the bottom of Finder windows.",
                key: "ShowStatusBar",
                defaultValue: false,
                searchTerms: ["finder status bar", "free space", "状态栏"],
                executionClass: .directRequiresRestart
            ),
            defaultsChoice(
                id: "finder.search-scope",
                title: "When Performing a Search",
                description: "Choose the default scope for Finder searches.",
                category: .finder,
                domain: finderDomain,
                key: "FXDefaultSearchScope",
                defaultValue: "SCev",
                options: [
                    .init(id: "SCev", title: "Search This Mac"),
                    .init(id: "SCcf", title: "Search the Current Folder"),
                    .init(id: "SCsp", title: "Use the Previous Search Scope"),
                ],
                searchTerms: ["search current folder", "finder search scope", "搜索范围"],
                destination: finderDestination,
                executionClass: .directAppliesNextUse
            ),
            direct(
                id: "finder.new-window-target",
                title: "New Finder Windows Show",
                description: "Choose the default location for new Finder windows.",
                category: .finder,
                systemImage: "folder",
                schema: .directoryChoice(options: FinderWindowDestination.options),
                defaultValue: .choice(id: "PfAF"),
                executionClass: .directAppliesNextUse,
                searchTerms: ["new finder window destination", "finder opens", "新窗口位置"],
                destination: finderDestination,
                note: "Preserves the native target and path as one local rollback snapshot. Profiles accept named destinations only; custom folder URLs stay on this Mac. Verify using a new Finder window.",
                adapter: FinderWindowDestinationSystemSettingAdapter()
            ),
            providerBoolean(
                id: "dock.auto-hide",
                title: "Automatically Hide the Dock",
                description: "Hide the Dock when it is not in use.",
                category: .desktopAndDock,
                providerID: "auto-hide-dock",
                actionID: "set-enabled",
                readDomain: dockDomain,
                readKey: "autohide",
                defaultValue: false,
                searchTerms: ["dock disappear", "automatically hide dock", "隐藏 Dock"],
                destination: dockDestination,
                actionContext: actionContext
            ),
            defaultsDecimal(
                id: "dock.size",
                title: "Dock Size",
                description: "Adjust the base size of Dock icons.",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "tilesize",
                defaultValue: 48,
                range: 16 ... 128,
                step: 1,
                searchTerms: ["dock size", "dock icon size", "程序坞大小", "Dock 图标"],
                destination: dockDestination,
                dockPreference: .dockSize
            ),
            defaultsChoice(
                id: "dock.position",
                title: "Dock Position",
                description: "Choose which edge of the screen shows the Dock.",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "orientation",
                defaultValue: "bottom",
                options: [
                    .init(id: "left", title: "Left"),
                    .init(id: "bottom", title: "Bottom"),
                    .init(id: "right", title: "Right"),
                ],
                searchTerms: ["dock position", "dock left right", "程序坞位置"],
                destination: dockDestination,
                dockPreference: .screenEdge
            ),
            domainBoolean(
                id: "dock.magnification",
                title: "Dock Magnification",
                description: "Enlarge Dock icons when the pointer moves over them.",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "magnification",
                defaultValue: false,
                searchTerms: ["dock magnification", "dock icons bigger", "图标放大"],
                destination: dockDestination,
                dockPreference: .magnification
            ),
            defaultsDecimal(
                id: "dock.magnification-size",
                title: "Dock Magnification Size",
                description: "Adjust the size of magnified Dock icons.",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "largesize",
                defaultValue: 64,
                range: 16 ... 128,
                step: 1,
                searchTerms: ["dock magnification size", "large dock icons", "放大尺寸"],
                destination: dockDestination,
                dockPreference: .magnificationSize
            ),
            defaultsChoice(
                id: "dock.minimize-effect",
                title: "Minimize Windows Using",
                description: "Choose the animation used when minimizing windows to the Dock.",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "mineffect",
                defaultValue: "genie",
                options: [
                    .init(id: "genie", title: "Genie Effect"),
                    .init(id: "scale", title: "Scale Effect"),
                ],
                searchTerms: ["minimize effect", "genie scale", "最小化动画"],
                destination: dockDestination,
                dockPreference: .minimizeEffect
            ),
            domainBoolean(
                id: "dock.show-recents",
                title: "Show Recent Apps in the Dock",
                description: "Show recently used apps beside pinned apps.",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "show-recents",
                defaultValue: true,
                searchTerms: ["recent apps dock", "show recents", "最近使用 App"],
                destination: dockDestination,
                dockPreference: .showRecents
            ),
            domainBoolean(
                id: "dock.minimize-into-application",
                title: "Minimize Windows into Application Icon",
                description: "Keep minimized windows inside their app's Dock icon.",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "minimize-to-application",
                defaultValue: false,
                searchTerms: ["minimize into application icon", "dock window icon", "最小化至图标"],
                destination: dockDestination,
                dockPreference: .minimizeIntoApplication
            ),
            domainBoolean(
                id: "dock.animate-opening-applications",
                title: "Animate Opening Applications",
                description: "Bounce Dock icons when apps launch.",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "launchanim",
                defaultValue: true,
                searchTerms: ["animate opening applications", "bouncing dock icon", "启动动画"],
                destination: dockDestination,
                dockPreference: .animate
            ),
            domainBoolean(
                id: "dock.show-open-indicators",
                title: "Show Indicators for Open Applications",
                description: "Show a dot below the Dock icons of running apps.",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "show-process-indicators",
                defaultValue: true,
                searchTerms: ["show indicators open applications", "running app dot", "运行指示灯"],
                destination: dockDestination,
                dockPreference: .showIndicators
            ),
            defaultsChoice(
                id: "screenshots.format",
                title: "Screenshot Format",
                description: "Choose the image format for screenshots.",
                category: .screenshots,
                domain: screenshotDomain,
                key: "type",
                defaultValue: "png",
                options: [
                    .init(id: "png", title: "PNG"),
                    .init(id: "jpg", title: "JPEG"),
                    .init(id: "heic", title: "HEIC"),
                    .init(id: "pdf", title: "PDF"),
                    .init(id: "tiff", title: "TIFF"),
                ],
                searchTerms: ["screenshot jpg", "screen capture format", "截屏 JPEG"],
                destination: screenshotDestination,
                executionClass: .directAppliesNextUse
            ),
            domainBoolean(
                id: "screenshots.floating-thumbnail",
                title: "Show Floating Thumbnail",
                description: "Briefly show a preview in the corner after taking a screenshot.",
                category: .screenshots,
                domain: screenshotDomain,
                key: "show-thumbnail",
                defaultValue: true,
                searchTerms: ["floating thumbnail", "screenshot preview", "截屏缩略图"],
                destination: screenshotDestination,
                executionClass: .directAppliesNextUse
            ),
            domainBoolean(
                id: "screenshots.window-shadow",
                title: "Include Window Shadow",
                description: "Include the surrounding shadow in window screenshots.",
                category: .screenshots,
                domain: screenshotDomain,
                key: "disable-shadow",
                defaultValue: true,
                inverted: true,
                searchTerms: ["include window shadow", "screenshot shadow", "窗口阴影"],
                destination: screenshotDestination,
                executionClass: .directAppliesNextUse
            ),
            direct(
                id: "screenshots.destination",
                title: "Screenshot Save Location",
                description: "Choose the folder for new screenshots.",
                category: .screenshots,
                systemImage: "folder.badge.gearshape",
                schema: .url,
                defaultValue: .url(FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!),
                executionClass: .directAppliesNextUse,
                portability: .deviceSpecific,
                searchTerms: ["screenshot destination", "save screenshots", "截屏保存位置"],
                destination: screenshotDestination,
                note: "Stores and verifies a local directory path in the screencapture preference domain.",
                adapter: DefaultsSystemSettingAdapter.directoryURL(
                    domain: screenshotDomain,
                    key: "location",
                    defaultValue: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
                )
            ),
            systemAppearance(actionContext: actionContext),
            defaultsChoice(
                id: "appearance.show-scroll-bars",
                title: "Show Scroll Bars",
                description: "Choose when scroll bars are visible in windows.",
                category: .appearance,
                domain: globalDomain,
                key: "AppleShowScrollBars",
                defaultValue: "Automatic",
                options: [
                    .init(id: "Automatic", title: "Automatically Based on Mouse or Trackpad"),
                    .init(id: "WhenScrolling", title: "When Scrolling"),
                    .init(id: "Always", title: "Always"),
                ],
                searchTerms: ["show scroll bars", "scrollbar visibility", "显示滚动条"],
                destination: appearanceDestination,
                executionClass: .directAppliesNextUse
            ),
            domainBoolean(
                id: "appearance.scroll-bar-click-jumps-to-spot",
                title: "Jump to the Clicked Position in Scroll Bars",
                description: "Click a scroll bar to jump to that position instead of the next page.",
                category: .appearance,
                domain: globalDomain,
                key: "AppleScrollerPagingBehavior",
                defaultValue: false,
                searchTerms: ["click scroll bar jump", "scrollbar paging", "滚动条点按位置"],
                destination: appearanceDestination,
                executionClass: .directAppliesNextUse
            ),
            providerBooleanFromActionState(
                id: "display.true-tone",
                title: "True Tone",
                description: "Adjust display colors automatically to match ambient light.",
                category: .display,
                providerID: "display-true-color",
                readActionID: "toggle",
                writeActionID: "set-enabled",
                defaultValue: false,
                searchTerms: ["true tone", "display color", "原彩显示", "环境光"],
                destination: displayDestination,
                actionContext: actionContext
            ),
            providerBooleanFromActionState(
                id: "display.night-shift",
                title: "Night Shift",
                description: "Use warmer display colors in darker surroundings.",
                category: .display,
                providerID: "night-shift",
                readActionID: "toggle",
                writeActionID: "set-enabled",
                defaultValue: false,
                searchTerms: ["night shift", "warm display", "夜览", "蓝光"],
                destination: displayDestination,
                actionContext: actionContext
            ),
            menuBarAutoHide(actionContext: actionContext),
            domainBoolean(
                id: "desktop.show-items-on-desktop",
                title: "Show Items on Desktop",
                description: "Show files, folders, and other items on the desktop.",
                category: .desktopAndDock,
                domain: "com.apple.WindowManager",
                key: "StandardHideDesktopIcons",
                defaultValue: true,
                inverted: true,
                searchTerms: ["desktop icons", "show desktop items", "hide desktop icons", "桌面图标", "隐藏桌面项目"],
                destination: dockDestination,
                notificationName: .init("com.apple.ec.WindowManager.preferences")
            ),
            domainBoolean(
                id: "desktop.show-items-in-stage-manager",
                title: "Show Items in Stage Manager",
                description: "Show desktop items while Stage Manager is active.",
                category: .desktopAndDock,
                domain: "com.apple.WindowManager",
                key: "HideDesktop",
                defaultValue: true,
                inverted: true,
                searchTerms: ["stage manager desktop icons", "show desktop items", "幕前调度桌面图标"],
                destination: dockDestination,
                notificationName: .init("com.apple.ec.WindowManager.preferences")
            ),
            domainBoolean(
                id: "desktop.show-widgets-on-desktop",
                title: "Show Widgets on Desktop",
                description: "Show widgets directly on the desktop.",
                category: .desktopAndDock,
                domain: "com.apple.WindowManager",
                key: "StandardHideWidgets",
                defaultValue: true,
                inverted: true,
                searchTerms: ["desktop widgets", "hide widgets", "show widgets", "桌面小组件", "隐藏小组件"],
                destination: dockDestination,
                notificationName: .init("com.apple.ec.WindowManager.preferences")
            ),
            domainBoolean(
                id: "desktop.show-widgets-in-stage-manager",
                title: "Show Widgets in Stage Manager",
                description: "Show desktop widgets while Stage Manager is active.",
                category: .desktopAndDock,
                domain: "com.apple.WindowManager",
                key: "StageManagerHideWidgets",
                defaultValue: true,
                inverted: true,
                searchTerms: ["stage manager widgets", "show desktop widgets", "幕前调度小组件"],
                destination: dockDestination,
                notificationName: .init("com.apple.ec.WindowManager.preferences")
            ),
            providerBoolean(
                id: "desktop.stage-manager",
                title: "Stage Manager",
                description: "Organize windows and keep recent apps at the side of the screen.",
                category: .desktopAndDock,
                providerID: "stage-manager",
                actionID: "set-enabled",
                readDomain: "com.apple.WindowManager",
                readKey: "GloballyEnabled",
                defaultValue: false,
                searchTerms: ["stage manager", "window manager", "幕前调度"],
                destination: dockDestination,
                actionContext: actionContext
            ),
        ]
        return try SystemSettingCatalog(records: records, deferring: deferredSettingIDs)
    }

    // Finder and Screenshot preferences do not have System Settings panes.
    private static var finderDestination: SystemSettingSystemDestination? { nil }

    private static var dockDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Desktop-Settings.extension", anchor: nil)
    }

    private static var screenshotDestination: SystemSettingSystemDestination? { nil }

    private static var keyboardDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Keyboard-Settings.extension", anchor: nil)
    }

    private static var inputDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Trackpad-Settings.extension", anchor: nil)
    }

    private static var mouseDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Mouse-Settings.extension", anchor: nil)
    }

    private static var appearanceDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Appearance-Settings.extension", anchor: nil)
    }

    private static var displayDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Displays-Settings.extension", anchor: nil)
    }

    private static func accessibilityDestination(_ anchor: String) -> SystemSettingSystemDestination {
        let nativeAnchor: String = switch anchor {
        case "PointerControl": "AX_FEATURE_POINTERCONTROL"
        case "Display": "AX_CURSOR_SIZE"
        case "Zoom": "AX_FEATURE_ZOOM"
        case "Keyboard": "AX_FEATURE_KEYBOARD"
        default: anchor
        }
        return .init(pane: "com.apple.Accessibility-Settings.extension", anchor: nativeAnchor)
    }

    private static func systemAppearance(actionContext: @escaping () -> PluginActionExecutionHostContext?) -> SystemSettingRecord {
        let options: [SystemSettingChoice] = [.init(id: "auto", title: "Auto"),
                                              .init(id: "light", title: "Light"), .init(id: "dark", title: "Dark")]
        func reference(_ mode: String) throws -> ActionReference {
            .init(key: .init(providerID: "appearance", actionID: "set-mode"),
                  parameters: try .init(["mode": .string(mode)]))
        }
        return direct(
            id: "appearance.dark-mode", title: "System Appearance",
            description: "Choose Auto, Light, or Dark. macOS manages Auto; the selected mode stays Auto as the appearance changes.",
            category: .appearance, systemImage: "circle.lefthalf.filled",
            schema: .choice(options: options), defaultValue: .choice(id: "auto"),
            executionClass: .existingPluginProvider, requirements: .init(existingProviderID: "appearance"),
            searchTerms: ["appearance", "dark mode", "light appearance", "automatic appearance", "深色模式", "浅色", "自动外观"],
            destination: appearanceDestination,
            note: "Reads the selected appearance policy from the canonical provider; profiles and Undo preserve Auto independently of the current light/dark rendering.",
            adapter: ExistingPluginActionSettingAdapter(reader: {
                for option in options {
                    if let item = actionContext()?.item(for: try reference(option.id)),
                       item.availability.isAvailable, item.presentationState == .active {
                        return .choice(id: option.id)
                    }
                }
                throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("Could not read the appearance mode. Enable or update the Dark Mode plugin."))
            }, reference: { value in
                guard case let .choice(mode) = value, options.contains(where: { $0.id == mode }) else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return try reference(mode)
            }, context: actionContext)
        )
    }

    private static func menuBarAutoHide(
        actionContext: @escaping () -> PluginActionExecutionHostContext?
    ) -> SystemSettingRecord {
        let options: [SystemSettingChoice] = [
            .init(id: "always", title: "Always"),
            .init(id: "desktop-only", title: "On Desktop Only"),
            .init(id: "full-screen-only", title: "In Full Screen Only"),
            .init(id: "never", title: "Never"),
        ]
        func reference(_ mode: String) throws -> ActionReference {
            .init(
                key: .init(providerID: "auto-hide-menu-bar", actionID: "set-mode"),
                parameters: try .init(["mode": .string(mode)])
            )
        }
        return direct(
            id: "desktop.menu-bar-auto-hide",
            title: "Automatically Hide and Show the Menu Bar",
            description: "Choose when macOS automatically hides the menu bar.",
            category: .desktopAndDock,
            systemImage: "menubar.rectangle",
            schema: .choice(options: options),
            defaultValue: .choice(id: "never"),
            executionClass: .existingPluginProvider,
            requirements: .init(existingProviderID: "auto-hide-menu-bar"),
            searchTerms: ["auto hide menu bar", "menu bar desktop full screen", "隐藏菜单栏", "全屏菜单栏"],
            destination: dockDestination,
            note: "Reads and writes the canonical provider's exact four-state menu-bar policy so profiles and Undo preserve desktop and full-screen behavior independently.",
            adapter: ExistingPluginActionSettingAdapter(reader: {
                for option in options {
                    if let item = actionContext()?.item(for: try reference(option.id)),
                       item.availability.isAvailable,
                       item.presentationState == .active {
                        return .choice(id: option.id)
                    }
                }
                throw SystemSettingAdapterError.unsupported(
                    MacSettingsStrings.text("Could not read the menu bar visibility mode. Enable or update the Auto-hide Menu Bar plugin.")
                )
            }, reference: { value in
                guard case let .choice(mode) = value,
                      options.contains(where: { $0.id == mode }) else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return try reference(mode)
            }, context: actionContext)
        )
    }

    private static func direct(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        systemImage: String,
        schema: SystemSettingValueSchema,
        defaultValue: SystemSettingValue,
        executionClass: SystemSettingExecutionClass = .directVerified,
        requirements: SystemSettingRequirements = .init(),
        portability: SystemSettingPortability = .portable,
        searchTerms: [String],
        destination: SystemSettingSystemDestination?,
        note: String,
        adapter: any SystemSettingAdapter
    ) -> SystemSettingRecord {
        SystemSettingRecord(
            definition: SystemSettingDefinition(
                id: id,
                title: title,
                description: description,
                category: category,
                systemImage: systemImage,
                schema: schema,
                defaultValue: defaultValue,
                executionClass: executionClass,
                requirements: requirements,
                portability: portability,
                isSensitive: false,
                canReset: true,
                canRollback: executionClass != .guidedManual && executionClass != .unsupported,
                verificationAvailable: executionClass != .guidedManual && executionClass != .unsupported,
                searchTerms: searchTerms,
                destination: destination,
                implementationNote: note
            ),
            adapter: adapter
        )
    }

    private static func defaultsBoolean(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        key: String,
        defaultValue: Bool,
        searchTerms: [String],
        destination: SystemSettingSystemDestination?
    ) -> SystemSettingRecord {
        domainBoolean(
            id: id,
            title: title,
            description: description,
            category: category,
            domain: globalDomain,
            key: key,
            defaultValue: defaultValue,
            searchTerms: searchTerms,
            destination: destination
        )
    }

    private static func domainBoolean(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        domain: String,
        key: String,
        defaultValue: Bool,
        inverted: Bool = false,
        searchTerms: [String],
        destination: SystemSettingSystemDestination?,
        notificationName: Notification.Name? = nil,
        dockPreference: DockSystemEventsPreference? = nil,
        executionClass: SystemSettingExecutionClass = .directVerified
    ) -> SystemSettingRecord {
        let persistedAdapter = DefaultsSystemSettingAdapter.boolean(
            domain: domain,
            key: key,
            defaultValue: inverted ? !defaultValue : defaultValue,
            inverted: inverted,
            notificationName: notificationName
        )
        let adapter: any SystemSettingAdapter = if let dockPreference {
            DockSystemEventsSettingAdapter(
                persistedAdapter: persistedAdapter,
                preference: dockPreference
            )
        } else {
            persistedAdapter
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "switch.2",
            schema: .boolean,
            defaultValue: .boolean(defaultValue),
            executionClass: executionClass,
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads and writes a curated preference key and verifies the stored value.",
            adapter: adapter
        )
    }

    private static func finderBoolean(
        id: SystemSettingID,
        title: String,
        description: String,
        key: String,
        defaultValue: Bool,
        searchTerms: [String],
        executionClass: SystemSettingExecutionClass = .directVerified
    ) -> SystemSettingRecord {
        domainBoolean(
            id: id,
            title: title,
            description: description,
            category: .finder,
            domain: finderDomain,
            key: key,
            defaultValue: defaultValue,
            searchTerms: searchTerms,
            destination: finderDestination,
            executionClass: executionClass
        )
    }

    private static func defaultsInteger(
        id: SystemSettingID,
        title: String,
        description: String,
        key: String,
        defaultValue: Int,
        range: ClosedRange<Int>,
        searchTerms: [String],
        executionClass: SystemSettingExecutionClass
    ) -> SystemSettingRecord {
        return direct(
            id: id,
            title: title,
            description: description,
            category: .keyboard,
            systemImage: "keyboard",
            schema: .integer(range: range, step: 1),
            defaultValue: .integer(defaultValue),
            executionClass: executionClass,
            searchTerms: searchTerms,
            destination: keyboardDestination,
            note: "Reads and writes the global keyboard repeat preference and verifies persistence.",
            adapter: DefaultsSystemSettingAdapter.integer(
                domain: globalDomain,
                key: key,
                defaultValue: defaultValue
            )
        )
    }

    private static func defaultsDecimal(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        domain: String = globalDomain,
        key: String,
        defaultValue: Double,
        range: ClosedRange<Double>,
        step: Double,
        searchTerms: [String],
        destination: SystemSettingSystemDestination?,
        notificationName: Notification.Name? = nil,
        dockPreference: DockSystemEventsPreference? = nil,
        executionClass: SystemSettingExecutionClass = .directVerified
    ) -> SystemSettingRecord {
        let persistedAdapter = DefaultsSystemSettingAdapter.decimal(
            domain: domain,
            key: key,
            defaultValue: defaultValue,
            notificationName: notificationName
        )
        let adapter: any SystemSettingAdapter = if let dockPreference {
            DockSystemEventsSettingAdapter(
                persistedAdapter: persistedAdapter,
                preference: dockPreference
            )
        } else {
            persistedAdapter
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "slider.horizontal.3",
            schema: .decimal(range: range, step: step),
            defaultValue: .decimal(defaultValue),
            executionClass: executionClass,
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads and writes a bounded numeric preference and verifies the stored value.",
            adapter: adapter
        )
    }

    private static func defaultsChoice(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        domain: String,
        key: String,
        defaultValue: String,
        options: [SystemSettingChoice],
        searchTerms: [String],
        destination: SystemSettingSystemDestination?,
        notificationName: Notification.Name? = nil,
        dockPreference: DockSystemEventsPreference? = nil,
        executionClass: SystemSettingExecutionClass = .directVerified
    ) -> SystemSettingRecord {
        let persistedAdapter = DefaultsSystemSettingAdapter.choice(
            domain: domain,
            key: key,
            defaultValue: defaultValue,
            notificationName: notificationName
        )
        let adapter: any SystemSettingAdapter = if let dockPreference {
            DockSystemEventsSettingAdapter(
                persistedAdapter: persistedAdapter,
                preference: dockPreference
            )
        } else {
            persistedAdapter
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "list.bullet",
            schema: .choice(options: options),
            defaultValue: .choice(id: defaultValue),
            executionClass: executionClass,
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads and writes an allowlisted preference choice and verifies its stable identifier.",
            adapter: adapter
        )
    }

    private static func providerBoolean(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        providerID: String,
        actionID: String,
        readDomain: String,
        readKey: String,
        defaultValue: Bool,
        readBoolean: @escaping (Any?) -> Bool = { ($0 as? NSNumber)?.boolValue ?? false },
        searchTerms: [String],
        destination: SystemSettingSystemDestination?,
        actionContext: @escaping () -> PluginActionExecutionHostContext?
    ) -> SystemSettingRecord {
        let store = ProcessSystemDefaultsDomainStore()
        let reader: () async throws -> SystemSettingValue = {
            .boolean(readBoolean(try store.object(forKey: readKey, inDomain: readDomain)))
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "puzzlepiece.extension",
            schema: .boolean,
            defaultValue: .boolean(defaultValue),
            executionClass: .existingPluginProvider,
            requirements: .init(existingProviderID: providerID),
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads current state and delegates deterministic writes to the existing MacTools canonical action provider.",
            adapter: ExistingPluginActionSettingAdapter(
                reader: reader,
                reference: { value in
                    guard case let .boolean(enabled) = value else {
                        throw SystemSettingAdapterError.invalidValue
                    }
                    return ActionReference(
                        key: ActionKey(providerID: providerID, actionID: actionID),
                        parameters: try ActionParameterSet(["enabled": .boolean(enabled)])
                    )
                },
                context: actionContext
            )
        )
    }

    private static func providerBooleanFromActionState(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        providerID: String,
        readActionID: String,
        writeActionID: String,
        defaultValue: Bool,
        searchTerms: [String],
        destination: SystemSettingSystemDestination?,
        actionContext: @escaping () -> PluginActionExecutionHostContext?
    ) -> SystemSettingRecord {
        let readReference = ActionReference(
            key: ActionKey(providerID: providerID, actionID: readActionID)
        )
        let reader: () async throws -> SystemSettingValue = {
            guard let item = actionContext()?.item(for: readReference),
                  let presentationState = item.presentationState else {
                throw SystemSettingAdapterError.unreadable
            }
            return .boolean(presentationState == .active)
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "puzzlepiece.extension",
            schema: .boolean,
            defaultValue: .boolean(defaultValue),
            executionClass: .existingPluginProvider,
            requirements: .init(existingProviderID: providerID),
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads live canonical action presentation state and delegates deterministic writes to the existing MacTools provider.",
            adapter: ExistingPluginActionSettingAdapter(
                reader: reader,
                reference: { value in
                    guard case let .boolean(enabled) = value else {
                        throw SystemSettingAdapterError.invalidValue
                    }
                    return ActionReference(
                        key: ActionKey(providerID: providerID, actionID: writeActionID),
                        parameters: try ActionParameterSet(["enabled": .boolean(enabled)])
                    )
                },
                context: actionContext
            )
        )
    }
}
