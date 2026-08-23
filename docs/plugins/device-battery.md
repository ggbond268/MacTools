# 设备电量插件

`DeviceBattery` 在组件面板中聚合本机和外设电量。它不访问外部网页，也不会上传设备信息。

## 数据来源

- Mac 内置电池：`IOPowerSources`。
- iPhone / iPad / iPod touch / Vision Pro：运行时加载 macOS 自带的 `MobileDevice.framework`，通过已建立的 lockdown 配对会话读取 `com.apple.mobile.battery`；必要时回退到 diagnostics relay 的 `AppleSmartBattery` 快照。
- Apple Watch：通过已连接 iPhone 的 `com.apple.companion_proxy` 读取配对手表的电量与充电状态，不直接连接手表。
- 蓝牙与 Apple 外设：`system_profiler SPBluetoothDataType -json`、`IOBluetoothDevice`、相关 `IORegistry` 服务，以及系统 BatteryCenter / bluetoothd 近期本地日志中的电源状态。
- AirPods / Beats split batteries: when both left and right readings are available, they take precedence over a combined-earbuds reading. If either side is unavailable, the combined reading remains available. The charging case uses its own battery slot and does not, by itself, suppress the earbud reading.
- Bluetooth observations prefer physical identifiers exposed by system sources. When a source exposes no stable identifier, the implementation may use a source-local fallback identity, or correlate by name only when the candidate is unique; ambiguous cross-source matches remain unresolved. AirPods records with different identifiers are correlated only by a mutual one-to-one match with a shared valid serial, or under one of two constrained shadow-record patterns: a complete matching non-uniform left/right/case snapshot with matching firmware, or a connected BLE-only component record without a product ID, valid serial, or aggregate reading matched to one connected or paired known split-battery record with a valid group serial.
- AirPods / Beats model names: use a maintained product-ID mapping, falling back to names declared by the installed macOS CoreTypes catalog and device-reported model information.
- Recognized AirPods Max models are represented by one headset battery. The Smart Case is not treated as a battery component, and component-shaped readings are excluded for those recognized single-battery models.
- Battery percentage and charging state are resolved independently. Sources that expose only a percentage, including IOBluetooth and the standard GATT Battery Service, report an unknown charging state instead of assuming that the device is not charging. Only explicit state fields or flags can replace a known charging state.
- Apple mobile devices use their stable MobileDevice identifier as the physical identity. The device-reported Bluetooth address is retained as a strong alias, allowing USB, Wi-Fi, and BLE observations of the same physical device to consolidate without comparing display names. Unmatched BatteryCenter mobile records are excluded because BatteryCenter identifiers cannot be proven equivalent to MobileDevice identifiers.
- When a current MobileDevice percentage lacks charging fields, a current diagnostics-registry state can complete that observation without replacing its percentage. A recent explicit state may bridge a transient read failure for up to three minutes without advancing its original observation time; a confirmed disconnection clears the device immediately.
- Rapoo VT-series mice use the vendor HID interface matched by `VendorID = 0x24AE`, `PrimaryUsagePage = 0xFF00`, and `PrimaryUsage = 0x0001`. Each connected HID device keeps its own stable snapshot instead of replacing the previously detected mouse.

The AirPods component keys exposed by `system_profiler` and local logs, the installed CoreTypes product metadata, and Apple headphone manufacturer advertisements are undocumented macOS implementation details rather than stable public APIs. Unknown advertisement packet shapes and battery nibble values are ignored.

雷柏鼠标电量来自本机 HID input report，不访问雷柏网页，也不请求网络。第一版只监听设备主动上报，不主动发送刷新命令。

Bluetooth log fallback queries a bounded recent window of the local unified log with predicates, an output filter, and a timeout, then correlates usable readings with known battery targets. AirPods and Beats advertisement scans run for a short, bounded interval only when connected Apple headphone candidates require them. Standard GATT battery devices are retrieved through the Battery Service first; unresolved GATT targets use a Battery-Service-scoped scan, while an all-advertisement scan is reserved for Apple headphone manufacturer data that has no public service-UUID contract. The plugin stops each scan promptly, does not keep an all-device BLE scan running, and keeps all readings local.

## Sampling and energy use

- Opening the component requests an immediate asynchronous refresh while the UI stays responsive and keeps any available snapshot visible. Expensive supplemental state sources use a short revalidation throttle so repeated opens do not launch duplicate work.
- Bluetooth and Apple mobile-device polling use the shorter visible-panel cadence. Low-battery monitoring uses a five-minute base background cadence.
- While the component is visible, the lighter BatteryCenter state fallback can refresh with the Bluetooth sampling cycle; the more expensive bluetoothd power-log fallback remains throttled to five minutes. Background sampling remains bounded by the five-minute Bluetooth cadence.
- Supplemental observations retain their own timestamps and source-specific freshness limits. Battery percentage and charging state also retain separate observation times, so a newly read level cannot make a carried charging state appear newer than it is. Fast-changing BatteryCenter and advertisement state expires sooner than the bluetoothd fallback, so a new percentage or explicit state is not overwritten or indefinitely renewed by an older source.
- Closing the panel while monitoring remains enabled changes the next deadline without triggering another immediate scan.
- Layout-only changes do not intentionally restart active samplers, and changing one source does not restart unrelated source loops.
- Power-source and Bluetooth connection events still trigger source-targeted refreshes, while screen lock, display sleep, and system sleep suspend deferrable work.

These measures reduce avoidable polling, process launches, and Bluetooth discovery. Actual refresh duration still depends on macOS system services and the connected devices.

Apple 移动设备首次使用时，需要通过数据线连接 Mac 并在设备上选择“信任”。在 Finder 中启用通过 Wi-Fi 显示设备后，同一局域网内可无线读取。该路径使用 Apple 未公开但随 macOS 提供的系统框架；组件面板可见时按 90 秒最短间隔刷新，面板隐藏后放宽到 5 分钟。框架、符号或返回字段变化时会无崩溃降级，不影响其他电量来源。设备 UDID 不进入 UI 或普通日志，仅使用本地稳定摘要做去重。

Apple Pencil 不采用 AirBattery 的长时间设备 syslog 扫描方案。该方案本身属于 Beta，首次发现慢且可能增加 iPad 耗电，不符合 MacTools 的轻量、非干扰目标。

## 雷蛇设备说明

AirBattery 没有雷蛇专用 VID/PID 表、HyperSpeed 接收器命令或厂商 HID 电量协议。它对雷蛇设备的兼容来自通用 `bluetoothd` 电源日志和标准 BLE Battery Service (`0x180F` / `0x2A19`)。DeviceBattery 已具备对应的通用路径，因此蓝牙直连、且由设备或 macOS 上报电量的雷蛇鼠标、键盘或耳机可以显示；使用 2.4G HyperSpeed 接收器且不向系统暴露电量的型号仍需按具体设备协议单独适配。

## 雷柏 HID 维护依据

雷柏 Hub 网页使用 WebHID 直连本机设备，已知过滤条件为 `vendorId = 0x24AE`、`usagePage = 0xFF00`。VT7 在 macOS `ioreg` 中对应厂商接口 `ProductID = 5139`、`PrimaryUsagePage = 65280`、`PrimaryUsage = 1`；雷柏网页设备表将 `5139` 映射到 Web 产品 ID `17939`，型号为 `VT7`，协议字段为 `protocol = "1"`、`featureReportId = 8`。

当前实现固化了已确认的 VT 系列接收器 Product ID 与 Web 产品 ID 映射，并只处理 input report id `7`。协议 1 的电量解析优先使用 `status = data[6]`、`battery = data[7]`，同时保留 `status = data[7]`、`battery = data[8]` 作为候选偏移。`status` 取值 `1` 表示正常，`2` 表示充电中，`battery` 只接受 `0...100`。

## Layout

The component settings provide two layouts:

- List: keeps long device names and split AirPods readings easy to scan.
- Rings: emphasizes battery levels while retaining the same device data and controls.

Both layouts consume the full normalized device snapshot without applying a fixed item-count truncation. When the resulting component is taller than the panel, the host panel provides vertical scrolling instead of replacing trailing items with an overflow count.

## 低电量通知

插件设置中可开启低电量通知，并设置触发百分比。设备电量低于该百分比、且未处于充电或外接电源状态时，插件会发送系统通知；同一次检测中有多台设备低电量时合并为一条通知。

## 权限

系统电池、Apple 移动设备和蓝牙系统信息通常不需要额外授权。Apple 移动设备需要先信任此 Mac。雷柏 HID 读取可能被 macOS 归入输入监控权限；如果 `IOHIDManagerOpen` 返回 `0xE00002E2`，插件会提示打开输入监控设置。
