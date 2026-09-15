import AppKit
import SwiftUI
import MacToolsPluginKit

struct PanelSymbolPicker: View {
    let selected: String
    let onSelect: (String) -> Void
    @State private var query = ""
    @State private var category = "全部"

    private static let groups: [(String, String, [String])] = [
        (
            "常用", "常用 favorite panel home star",
            [
                "square.grid.2x2", "switch.2", "star", "heart", "house", "bookmark", "flag", "circle.grid.3x3",
                "sidebar.left", "rectangle.3.group",
                "square.stack", "square.grid.3x3", "list.bullet", "line.3.horizontal.decrease.circle",
                "magnifyingglass", "pin", "tag", "paperclip", "link", "location", "map", "person", "person.2",
                "infinity",
            ]
        ),
        (
            "工作", "工作 work code tools documents",
            [
                "briefcase", "folder", "doc", "tray", "calendar", "checklist", "pencil", "hammer",
                "wrench.and.screwdriver", "terminal", "curlybraces", "command",
                "doc.text", "doc.on.doc", "clipboard", "note.text", "envelope", "bubble.left.and.bubble.right",
                "paperplane", "archivebox", "shippingbox", "printer", "chart.bar", "chart.pie",
            ]
        ),
        (
            "系统", "系统 system computer display network",
            [
                "gearshape", "desktopcomputer", "laptopcomputer", "display", "keyboard", "computermouse", "cpu",
                "memorychip", "internaldrive", "wifi", "network", "antenna.radiowaves.left.and.right",
                "externaldrive", "server.rack", "cloud", "arrow.down.circle", "arrow.up.circle",
                "externaldrive.connected.to.line.below", "cable.connector", "powerplug",
                "dot.radiowaves.left.and.right", "iphone", "ipad", "app.badge",
            ]
        ),
        (
            "生活", "生活 life music game photo time",
            [
                "music.note", "headphones", "play.rectangle", "photo", "camera", "gamecontroller", "book",
                "cup.and.saucer", "clock", "bell", "globe", "airplane",
                "film", "tv", "radio", "mic", "speaker.wave.2", "alarm", "stopwatch", "timer", "figure.walk",
                "bicycle", "wallet.pass", "cart",
            ]
        ),
        (
            "状态", "状态 status battery light security",
            [
                "bolt", "battery.100", "sun.max", "moon", "lightbulb", "thermometer.medium", "fan", "leaf", "shield",
                "lock", "eye", "sparkles",
                "checkmark.circle", "exclamationmark.triangle", "info.circle", "questionmark.circle",
                "lock.shield", "key", "hand.raised", "flame", "drop", "cloud.sun", "speedometer", "target",
            ]
        ),
    ]

    // Symbol availability is fixed for the running OS; resolve it once instead of
    // constructing an NSImage for every candidate on each search or view update.
    private static let availableGroups = groups.map { group in
        (group.0, group.1, group.2.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
    }

    private static let titles: [String: String] = [
        "square.grid.2x2": "网格",
        "switch.2": "开关",
        "star": "星标",
        "heart": "心形",
        "house": "主页",
        "bookmark": "书签",
        "flag": "旗标",
        "circle.grid.3x3": "圆点网格",
        "sidebar.left": "侧栏",
        "rectangle.3.group": "分组",
        "briefcase": "公文包",
        "folder": "文件夹",
        "doc": "文档",
        "tray": "收件箱",
        "calendar": "日历",
        "checklist": "清单",
        "pencil": "铅笔",
        "hammer": "锤子",
        "wrench.and.screwdriver": "工具",
        "terminal": "终端",
        "curlybraces": "代码",
        "command": "命令",
        "gearshape": "设置",
        "desktopcomputer": "台式电脑",
        "laptopcomputer": "笔记本电脑",
        "display": "显示器",
        "keyboard": "键盘",
        "computermouse": "鼠标",
        "cpu": "处理器",
        "memorychip": "内存",
        "internaldrive": "磁盘",
        "wifi": "无线网络",
        "network": "网络",
        "antenna.radiowaves.left.and.right": "无线信号",
        "music.note": "音乐",
        "headphones": "耳机",
        "play.rectangle": "视频",
        "photo": "照片",
        "camera": "相机",
        "gamecontroller": "游戏",
        "book": "图书",
        "cup.and.saucer": "咖啡",
        "clock": "时钟",
        "bell": "通知",
        "globe": "地球",
        "airplane": "飞机",
        "bolt": "闪电",
        "battery.100": "电池",
        "sun.max": "太阳",
        "moon": "月亮",
        "lightbulb": "灯泡",
        "thermometer.medium": "温度",
        "fan": "风扇",
        "leaf": "树叶",
        "shield": "盾牌",
        "lock": "锁定",
        "eye": "眼睛",
        "sparkles": "光芒",
        "square.stack": "堆叠",
        "square.grid.3x3": "九宫格",
        "list.bullet": "列表",
        "line.3.horizontal.decrease.circle": "筛选",
        "magnifyingglass": "搜索",
        "pin": "图钉",
        "tag": "标签",
        "paperclip": "附件",
        "link": "链接",
        "location": "定位",
        "map": "地图",
        "person": "用户",
        "person.2": "群组",
        "infinity": "无限",
        "doc.text": "文本",
        "doc.on.doc": "副本",
        "clipboard": "剪贴板",
        "note.text": "备忘录",
        "envelope": "邮件",
        "bubble.left.and.bubble.right": "对话",
        "paperplane": "发送",
        "archivebox": "归档",
        "shippingbox": "包裹",
        "printer": "打印机",
        "chart.bar": "柱状图",
        "chart.pie": "饼图",
        "externaldrive": "外置磁盘",
        "server.rack": "服务器",
        "cloud": "云",
        "arrow.down.circle": "下载",
        "arrow.up.circle": "上传",
        "externaldrive.connected.to.line.below": "网络磁盘",
        "cable.connector": "连接线",
        "powerplug": "电源插头",
        "dot.radiowaves.left.and.right": "热点",
        "iphone": "手机",
        "ipad": "平板",
        "app.badge": "应用",
        "film": "影片",
        "tv": "电视",
        "radio": "广播",
        "mic": "麦克风",
        "speaker.wave.2": "扬声器",
        "alarm": "闹钟",
        "stopwatch": "秒表",
        "timer": "计时器",
        "figure.walk": "步行",
        "bicycle": "自行车",
        "wallet.pass": "钱包",
        "cart": "购物车",
        "checkmark.circle": "完成",
        "exclamationmark.triangle": "警告",
        "info.circle": "信息",
        "questionmark.circle": "帮助",
        "lock.shield": "安全",
        "key": "钥匙",
        "hand.raised": "隐私",
        "flame": "火焰",
        "drop": "水滴",
        "cloud.sun": "天气",
        "speedometer": "速度",
        "target": "目标",
    ]

    var body: some View {
        let visibleSymbols = symbols
        VStack(alignment: .leading, spacing: 12) {
            Text(FeatureL10n.string("选择图标"))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            TextField(FeatureL10n.string("搜索图标"), text: $query)
                .textFieldStyle(.roundedBorder)
            Picker(FeatureL10n.string("分类"), selection: $category) {
                Text(FeatureL10n.string("全部")).tag("全部")
                ForEach(Self.availableGroups, id: \.0) { group in Text(FeatureL10n.string(group.0)).tag(group.0) }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(minWidth: 120, idealWidth: 150, maxWidth: 180)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 6), spacing: 6) {
                    ForEach(visibleSymbols, id: \.self) { symbol in
                        Button {
                            onSelect(symbol)
                        } label: {
                            Image(systemName: symbol)
                                .font(.title3)
                                .foregroundStyle(selected == symbol ? Color.accentColor : .primary)
                                .frame(width: 38, height: 36)
                                .background {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(
                                            selected == symbol
                                                ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(FeatureL10n.string(Self.titles[symbol] ?? symbol))
                        .accessibilityLabel(FeatureL10n.string(Self.titles[symbol] ?? symbol))
                        .accessibilityAddTraits(selected == symbol ? .isSelected : [])
                    }
                }
                if visibleSymbols.isEmpty { Text(FeatureL10n.string("没有匹配的图标")).foregroundStyle(.secondary) }
            }
            .frame(height: 246)
        }
        .padding(16)
        .frame(width: 292)
    }

    private var symbols: [String] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.availableGroups.filter { category == "全部" || $0.0 == category }.flatMap { group in
            group.2.filter { symbol in
                search.isEmpty || symbol.localizedCaseInsensitiveContains(search)
                    || (Self.titles[symbol]?.localizedCaseInsensitiveContains(search) ?? false)
                    || FeatureL10n.string(Self.titles[symbol] ?? symbol).localizedCaseInsensitiveContains(search)
                    || group.1.localizedCaseInsensitiveContains(search)
            }
        }
    }
}
