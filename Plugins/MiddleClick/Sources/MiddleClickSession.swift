import AppKit
import CoreFoundation
import CoreGraphics
import Foundation
import IOKit
import MultitouchSupport
import OSLog

/// 管理触控板多点触控设备回调，检测到指定手指数后通过 CGEvent tap 把系统左键事件原地改为中键。
///
/// 工作原理（行为思路参考 MiddleClick 的 tap-to-click 模式）：
/// - 多点触控回调维护 `threeDown` 标志（三指正在触碰 → true）。
/// - CGEvent tap 在主线程拦截 `leftMouseDown/Up`，三指期间将其原地改为 `otherMouseDown/Up`。
/// - 系统"轻点点按"产生的左键事件被转换，永不传递给应用，不额外合成事件，不会双击。
///
/// 系统恢复处理（对齐 artginzburg/MiddleClick）：
/// - `didWakeNotification`：合盖唤醒后多点触控驱动可能还没就绪，延迟一段时间再重建监听。
/// - `CGDisplayRegisterReconfigurationCallback`：显示器重新配置时也安排一次重启。
/// - IOKit `AppleMultitouchDevice` first-match 通知：外接或内置触控板重新枚举时立即重启监听。
///
/// 该类的可变状态既被多点触控/CGEvent tap 的 C 回调线程读写，也被主线程读写，
/// 因此显式标记为 `@unchecked Sendable`。所有 lifecycle 方法（start/stop/activate/deactivate
/// 以及内部 restart 调度）都假定在主线程上调用。
final class MiddleClickSession: @unchecked Sendable {

    // MARK: - CGEvent Tap State（CGEvent tap 与 C 回调线程均可读写）

    /// 当前是否有所需手指数正在触碰（供 CGEvent tap 使用）
    nonisolated(unsafe) var threeDown = false
    /// CGEvent tap 已把一次 leftMouseDown 转换为 otherMouseDown，等待配对的 Up
    nonisolated(unsafe) var wasThreeDown = false

    // MARK: - Config（由主线程设置，回调线程读取）

    nonisolated(unsafe) var requiredFingerCount: Int = 3

    // MARK: - Infrastructure

    private var devices: [MTDevice] = []
    private var eventTap: CFMachPort?
    private var runLoopSrc: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var ioNotificationPort: IONotificationPortRef?
    private var ioIterator: io_iterator_t = 0
    private var displayCallbackRegistered = false
    private var restartWorkItem: DispatchWorkItem?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "MiddleClickSession")

    /// 合盖唤醒后多点触控驱动可能还没就绪，延迟一段时间再重建监听。
    /// 与 artginzburg/MiddleClick 对齐取 10 秒：长时间合盖后驱动重新枚举耗时在不同机型上差异较大，
    /// 短延迟（2~3 秒）实测会复现"中键失效"。用户解锁后头几秒通常不会立刻用到中键，10 秒不可感知。
    private static let wakeRestartDelay: TimeInterval = 10

    // MARK: - 单例引用（供 C 回调访问）

    nonisolated(unsafe) static weak var activeSession: MiddleClickSession?

    // MARK: - MTDeviceCreateList（私有符号，通过 @_silgen_name 链接）

    @_silgen_name("MTDeviceCreateList")
    private static func _mtDeviceCreateList() -> Unmanaged<CFMutableArray>?

    private static func createDeviceList() -> [MTDevice] {
        _mtDeviceCreateList()?.takeUnretainedValue() as? [MTDevice] ?? []
    }

    // MARK: - 多点触控回调
    //
    // 只维护 threeDown 标志，不做手势识别。

    private let touchCallback: MTFrameCallbackFunction = { _, data, nFingers, _, _ in
        guard let session = MiddleClickSession.activeSession else { return }
        session.threeDown = (nFingers == Int32(session.requiredFingerCount))
    }

    // MARK: - CGEvent Tap

    private func startEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)

        // @convention(c) 闭包不能捕获上下文，self 通过 userInfo 指针传入
        let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let ptr = userInfo else { return Unmanaged.passUnretained(event) }
            let session = Unmanaged<MiddleClickSession>.fromOpaque(ptr).takeUnretainedValue()
            let kCenter = Int64(CGMouseButton.center.rawValue)
            let passthrough = Unmanaged.passUnretained(event)

            let current = MiddleClickPairing.State(
                threeDown: session.threeDown,
                wasThreeDown: session.wasThreeDown
            )
            let decision = MiddleClickPairing.decide(type: type, state: current)
            // Write back only changed flags: the touch callback thread may set
            // `threeDown = true` between our read and write, and an
            // unconditional write-back would stomp it.
            if decision.state.threeDown != current.threeDown {
                session.threeDown = decision.state.threeDown
            }
            if decision.state.wasThreeDown != current.wasThreeDown {
                session.wasThreeDown = decision.state.wasThreeDown
            }

            switch decision.rewrite {
            case .middleDown:
                event.type = .otherMouseDown
                event.setIntegerValueField(.mouseEventButtonNumber, value: kCenter)
            case .middleUp:
                event.type = .otherMouseUp
                event.setIntegerValueField(.mouseEventButtonNumber, value: kCenter)
            case .none:
                break
            }

            return passthrough
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("failed to create CGEvent tap; check Accessibility permission")
            return
        }

        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSrc = src
        logger.info("CGEvent tap started")
    }

    private func stopEventTap() {
        guard let tap = eventTap, CFMachPortIsValid(tap) else {
            eventTap = nil
            runLoopSrc = nil
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let src = runLoopSrc {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSrc = nil
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        logger.info("CGEvent tap stopped")
    }

    // MARK: - 多点触控监听

    private func startTouchListeners() {
        guard devices.isEmpty else { return }
        devices = Self.createDeviceList()
        if devices.isEmpty {
            logger.warning("no multitouch devices detected; waiting for IOKit notification or wake retry")
        }
        devices.forEach { $0.register(contactFrameCallback: touchCallback); $0.start(runMode: 0) }
    }

    private func stopTouchListeners() {
        devices.forEach { $0.unregister(contactFrameCallback: touchCallback); $0.stop(); $0.release() }
        devices.removeAll()
        threeDown = false
        wasThreeDown = false
    }

    // MARK: - Start / Stop

    func start() {
        startTouchListeners()
        startEventTap()
        observeSystemWake()
        observeMultitouchDeviceArrival()
        observeDisplayReconfiguration()
        logger.info("multitouch listener started deviceCount=\(self.devices.count, privacy: .public)")
    }

    func stop() {
        cancelPendingRestart()
        removeDisplayReconfigurationObserver()
        removeMultitouchDeviceObserver()
        removeSystemWakeObserver()
        stopEventTap()
        stopTouchListeners()
        logger.info("multitouch listener stopped")
    }

    func activate() {
        MiddleClickSession.activeSession?.stop()
        MiddleClickSession.activeSession = self
        start()
    }

    func deactivate() {
        if MiddleClickSession.activeSession === self {
            MiddleClickSession.activeSession = nil
        }
        stop()
    }

    // MARK: - 系统恢复：重启监听

    /// 重启不稳定的监听器（CGEvent tap 与 MTDevice）。session 本身保留，
    /// 但所有底层监听重新创建，对应合盖唤醒、显示器重新配置、触控板重新枚举等场景。
    private func restartListeners() {
        logger.info("rebuilding multitouch and CGEvent tap listeners")
        stopEventTap()
        stopTouchListeners()
        startTouchListeners()
        startEventTap()
        logger.info("listener rebuild completed deviceCount=\(self.devices.count, privacy: .public)")
    }

    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        logger.info("scheduled listener restart reason=\(reason, privacy: .public) delay=\(delay, privacy: .public)")
        cancelPendingRestart()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.restartListeners()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRestart() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
    }

    // MARK: - NSWorkspace wake 通知

    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRestart(after: Self.wakeRestartDelay, reason: "systemWake")
        }
    }

    private func removeSystemWakeObserver() {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    // MARK: - IOKit 触控板设备到达通知

    /// 监听 `AppleMultitouchDevice` 的 first-match 通知。当系统重新枚举触控板（合盖唤醒、外接拔插、
    /// 驱动重置）时，立刻安排一次小延迟重启，确保 MTDevice 列表与现实设备保持一致。
    private func observeMultitouchDeviceArrival() {
        guard ioNotificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("failed to create IONotificationPort; skipping device arrival observer")
            return
        }

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                // 必须 drain 迭代器，否则不会再触发后续通知
                MiddleClickSession.drainIterator(iterator)
                guard let userData else { return }
                let session = Unmanaged<MiddleClickSession>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    session.scheduleRestart(after: 2, reason: "multitouchDeviceArrived")
                }
            },
            userInfo,
            &iterator
        )

        guard result == KERN_SUCCESS else {
            logger.error("IOServiceAddMatchingNotification failed result=\(result, privacy: .public)")
            IONotificationPortDestroy(port)
            return
        }

        // 首次注册必须 drain 一次，激活通知
        Self.drainIterator(iterator)

        ioNotificationPort = port
        ioIterator = iterator
    }

    private func removeMultitouchDeviceObserver() {
        if ioIterator != 0 {
            IOObjectRelease(ioIterator)
            ioIterator = 0
        }
        if let port = ioNotificationPort {
            IONotificationPortDestroy(port)
            ioNotificationPort = nil
        }
    }

    private static func drainIterator(_ iterator: io_iterator_t) {
        while true {
            let next = IOIteratorNext(iterator)
            if next == 0 { break }
            IOObjectRelease(next)
        }
    }

    // MARK: - 显示器重配置回调

    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userData in
        let interesting: CGDisplayChangeSummaryFlags = [.setModeFlag, .addFlag, .removeFlag, .disabledFlag]
        guard !flags.intersection(interesting).isEmpty else { return }
        guard let userData else { return }
        let session = Unmanaged<MiddleClickSession>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
            session.scheduleRestart(after: 2, reason: "displayReconfigured")
        }
    }

    /// 监听显示器重新配置事件。合盖、外接显示器接入、显示器拓扑变化都可能让多点触控通道失效，
    /// 与 artginzburg/MiddleClick 一致：仅在出现 setMode/add/remove/disabled 这类实质变化时安排重启。
    private func observeDisplayReconfiguration() {
        guard !displayCallbackRegistered else { return }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, userInfo)
        if result == .success {
            displayCallbackRegistered = true
        } else {
            logger.error("CGDisplayRegisterReconfigurationCallback failed result=\(result.rawValue, privacy: .public)")
        }
    }

    private func removeDisplayReconfigurationObserver() {
        guard displayCallbackRegistered else { return }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback, userInfo)
        displayCallbackRegistered = false
    }
}
