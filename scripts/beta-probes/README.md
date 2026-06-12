# beta-probes — macOS beta 私有面巡检探针

重建自 `docs/superpowers/specs/2026-06-12-macos27-beta-impact.md` §D 的静默探针，
固化为可重复执行的脚本。**每个新 beta seed 装上后跑一次**，即可重验所有
「当前活着但每 seed 必验」的私有/脆弱系统面。

## 用法

```bash
# 全部探针（串行，约 3–5 分钟，log show 占大头）
./scripts/beta-probes/run-all.sh

# 单个探针
swift scripts/beta-probes/probe-gamma.swift
```

`run-all.sh` 汇总所有 `[status] 探针名: 详情` 行并打统计表；
**任何 `[broken]` → 退出码 1**（探针崩溃/编译失败也按 broken 计，超时按 inconclusive 计）。

## 状态语义

| 状态 | 含义 |
|------|------|
| `ok` | 该系统面健康（或已从回归恢复，可考虑回退 workaround） |
| `degraded` | 已知回归仍在，但 App 已绕过/有兜底 —— 持续观察，无需立即行动 |
| `broken` | App **当前代码路径**依赖的面坏了 —— 需要行动，run-all 非零退出 |
| `inconclusive` | 环境不足以定论（离线、设备空闲、超时等），按详情提示重跑 |
| `skip` | 本机硬件/环境不适用（无外接屏、无刘海、非 Apple silicon 等） |

## 安全红线（全部探针严格遵守）

- 只读：不 CGEventPost/合成任何事件、不截图、不写 SMC/gamma/Night Shift、不弹权限框
- 不 sudo、不留驻进程；`log show` 限定 `--last 1m`，每个探针有硬超时
- DDC 探针只发 VCP 0x10 的 *读* 请求（DDC get-VCP 协议本身需写 I2C 请求包，但绝不 set）

## 探针清单

| 文件 | 结果行 | 测什么 | 对应插件/链路 |
|------|--------|--------|----------------|
| `probe-gamma.swift` | `gamma-capacity-fixpath` | CGDisplayGammaTableCapacity + 按容量整表读（App 现行路径） | DisplayBrightness gamma 回退链（`DisplayBrightnessBackends.swift`） |
| | `gamma-legacy-size-query` | 旧 capacity=0 查表长惯用法是否仍回归（26A5353q 返回 1001） | 同上（已迁移，观察是否恢复） |
| `probe-window-topology.swift` | `window-topology-census` | layer 25 per-item 状态项窗口数 vs 单一 Menubar 窗口（layer 24）；须多窗口多 owner 才认 pre-27，防单个第三方覆盖窗误判 | MenuBarHidden 事件合成 gate（fail-closed 依据） |
| | `desktop-tier-math` | 壁纸层 < 遮罩层 < 桌面图标层 + 覆盖窗 z 序余量 | HideNotch 遮罩（`HideNotchWallpaperRenderer`）、清洁模式/Shade 覆盖窗 |
| | `notch-geometry` | NSScreen auxiliaryTop 区 / safeAreaInsets / 菜单栏高度 | HideNotch（`HideNotchDisplayCatalog`） |
| `probe-private-input.swift` | `corebrightness-cbbluelightclient` | dlopen + 三 selector 响应 + getBlueLightStatus 真实读 | NightShift / DisplayTrueColor |
| | `multitouchsupport-symbols` | dlopen + 9 符号 + MTDeviceCreateList 数量（不 Start） | MiddleClick |
| `probe-display-private.swift` | `display-private-symbols` | DisplayServices/SkyLight/CGS/CoreDisplay 13 个 dlsym 符号（含 MenuBarHidden 的 SLWindowListCreateImageFromArray 与 CGS* 仅做存在性检查，不生成任何截图） | DisplayBrightness、HideNotch、MenuBarHidden |
| | `sls-managed-display-spaces-schema` | SLSCopyManagedDisplaySpaces 键完整性（Display Identifier/Current Space/Spaces/uuid/type） | HideNotch Space 跟踪 |
| | `coredisplay-info-dictionary` | CoreDisplay_DisplayCreateInfoDictionary 的 IODisplayLocation 键 | DisplayBrightness DDC 显示器匹配 |
| `probe-iokit-ddc.swift` | `ddc-registry-census` | AppleCLCD2 / IOMobileFramebufferShim / DCPAVServiceProxy 计数 + CGSServiceForDisplayNumber | DisplayBrightness DDC 匹配（shim 单点依赖监控） |
| | `ddc-endtoend-readonly` | 有外接屏时 IOAVServiceCreateWithService + VCP 0x10 只读 | DisplayBrightness 外接屏亮度 |
| `probe-smc-readonly.swift` | `smc-keyinfo-readonly` | AppleSMC selector-2 keyInfo（CHIE/F0Ac/FNum/F0Mn/F0Mx；绝不写） | BatteryChargeLimit、FanControl、SystemStatus |
| `probe-events-permissions.swift` | `permission-status-bits` | AXIsProcessTrusted / IOHIDCheckAccess / CGPreflight*（只读不弹窗） | 全局权限面 |
| | `carbon-hotkey-registration` | Register + 立即 Unregister 全修饰 F15（不留驻） | GlobalShortcutManager 注册链 |
| `probe-log-show.swift` | `log-predicate-with-process` | `--process`+`--predicate` 是否仍吞 predicate（--last 1m 限时）；仅 predicate 的调用被拒（干净非零退出）按 broken 计 | DeviceBattery 蓝牙电量 log 通道 |
| `probe-plugin-trust.swift` | `secstaticcode-plugin-trust-chain` | SecStaticCode 对系统 App + 本地 Debug 插件 bundle 的校验链 | PluginTrustValidator |
| | `catalog-ed25519-canonicalization` | 线上 catalog Ed25519 验签（JSONSerialization 规范化漂移检测） | PluginCatalogVerifier / PluginCatalogSigning |

## 环境假设

- DDC 探针只在 **Apple silicon** 上有意义（非 arm64 自动 skip）。SMC 探针两种架构都跑：
  Intel 上 CH0B/BCLM 在、CHIE 缺属预期，输出按架构标注哪组键缺失是正常的。
- `ddc-endtoend-readonly` 需要外接显示器在线，否则 skip。
- `catalog-ed25519-canonicalization` 需要网络；公钥实时读取自
  `Configs/Release.xcconfig` 的 `PLUGIN_CATALOG_PUBLIC_KEY`，catalog URL 对应
  `PluginCatalogProvider.productionCatalogURL`（两处任一变更需同步本探针）。
- `secstaticcode-plugin-trust-chain` 的插件 bundle 一环依赖本地 Debug 构建产物
  （`build/DerivedData/Build/Products/Debug/*.bundle`），没有时仅校验系统 App。
- `log-predicate-with-process` 在蓝牙完全空闲的机器上可能 inconclusive，按提示重跑。

## 何时跑

- **每个新 beta seed 安装后**：一键 `run-all.sh`，对照上一个 seed 的输出找新增 broken/恢复项。
- 发版前在 beta 机上跑一次，确认分发链（Sparkle/catalog 签名）与私有面无新变化。
- 探针覆盖不了的决定性项（popover 锚定、全局快捷键派发、三指中键、SMC 写、真实更新安装）
  仍需按审计文档 §C 的上机验证批次人工确认。

## 已知基线（26A5353q，2026-06-12）

14 ok / 4 degraded / 0 broken。degraded 四项均为已绕过或有兜底的已知回归：
gamma 旧惯用法（1001）、菜单栏单窗口化、AppleCLCD2 消失（shim 兜底）、
`log show` predicate 被 `--process` 吞掉。其中任何一项转 `ok` 说明 Apple 已修复，
可评估回退对应 workaround；其余面转 `broken` 时按表中「对应插件/链路」定位入口。
