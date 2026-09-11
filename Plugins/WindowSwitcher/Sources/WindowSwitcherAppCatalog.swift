import AppKit
import ApplicationServices
import Foundation

/// AX objects are opaque handles. All reads and actions on them are serialized by
/// their owning process worker; only immutable snapshots cross to the main actor.
struct WindowSwitcherWindowSnapshot: @unchecked Sendable {
    let id: String
    let element: AXUIElement
    var title: String
    var minimized: Bool
    var bounds: CGRect
    var unavailable: Bool = false
}

struct WindowSwitcherScan: Sendable {
    var windows: [WindowSwitcherWindowSnapshot]
    var focusedID: String?
    var unavailable: Bool
    var windowListReadSucceeded = true
}

struct WindowSwitcherWindowIdentities {
    private var live: [(element: AXUIElement, id: String)] = []

    mutating func reconcile(_ elements: [AXUIElement]) -> [String] {
        live.removeAll { old in !elements.contains { CFEqual(old.element, $0) } }
        return elements.map { element in
            if let match = live.first(where: { CFEqual($0.element, element) }) { return match.id }
            let id = "window:\(UUID())"
            live.append((element, id))
            return id
        }
    }
}

enum WindowSwitcherActionResult: Equatable, Sendable {
    case succeeded, requested, unavailable, failed, cancelled
    var message: String? {
        switch self {
        case .succeeded, .cancelled: nil
        case .requested: "已发送请求；窗口可能需要确认保存。"
        case .unavailable: "窗口已关闭或暂时无法访问，请重新选择。"
        case .failed: "未能确认目标窗口，请重试或检查辅助功能权限。"
        }
    }
}

/// One bounded queue per application prevents a hung process from blocking the UI
/// or another application's discovery. Notifications coalesce with a polling fallback.
final class WindowSwitcherProcessWorker: @unchecked Sendable {
    let pid: pid_t
    let launchDate: Date?
    let lifetime = UUID()
    private let queue: DispatchQueue
    private let app: AXUIElement
    private let access: any WindowSwitcherAXAccess
    private var records: [WindowSwitcherWindowSnapshot] = []
    private var identities = WindowSwitcherWindowIdentities()
    private var observer: AXObserver?
    private var observedWindows: [AXUIElement] = []
    private var cursor = 0
    private var stopped = false
    private let invalidated: @Sendable () -> Void

    init(pid: pid_t, launchDate: Date?, access: any WindowSwitcherAXAccess = SystemWindowSwitcherAXAccess(), invalidated: @escaping @Sendable () -> Void) {
        self.access = access
        self.pid = pid
        self.launchDate = launchDate
        self.invalidated = invalidated
        queue = DispatchQueue(label: "WindowSwitcher.AX.\(pid)", qos: .userInitiated)
        app = AXUIElementCreateApplication(pid)
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            observedWindows.removeAll()
            records.removeAll()
            // Keep the callback context alive until removal on the callback's
            // own run loop; an in-progress main-thread callback cannot race free.
            DispatchQueue.main.async { [self] in
                if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
                observer = nil
            }
        }
    }

    func scan() async -> WindowSwitcherScan {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: read()) }
        }
    }

    private func read() -> WindowSwitcherScan {
        guard !stopped else { return WindowSwitcherScan(windows: [], unavailable: true, windowListReadSucceeded: false) }
        AXUIElementSetMessagingTimeout(app, 0.06)
        installObserver()
        guard let windows = copyWindows() else {
            return WindowSwitcherScan(windows: records.map { var r = $0; r.unavailable = true; return r }, unavailable: true, windowListReadSucceeded: false)
        }
        // CFEqual compares AX identity, not title or array position. New lifetimes
        // receive UUIDs; closed windows and app restarts cannot inherit old IDs.
        records.removeAll { old in !windows.contains { CFEqual(old.element, $0) } }
        observedWindows.removeAll { old in
            guard !windows.contains(where: { CFEqual(old, $0) }) else { return false }
            if let observer {
                for name in windowNotifications { AXObserverRemoveNotification(observer, old, name as CFString) }
            }
            return true
        }
        let windowIDs = identities.reconcile(windows)
        let start = ProcessInfo.processInfo.systemUptime
        var didRead = 0
        var metadataFailed = false
        let count = windows.count
        for offset in 0..<count {
            let index = (cursor + offset) % count
            let window = windows[index]
            AXUIElementSetMessagingTimeout(window, 0.06)
            let oldIndex = records.firstIndex { CFEqual($0.element, window) }
            switch snapshot(window, id: windowIDs[index]) {
            case let .eligible(snapshot):
                if let oldIndex { records[oldIndex] = snapshot } else { records.append(snapshot) }
                observe(window)
            case .excluded:
                if let oldIndex { records.remove(at: oldIndex) }
            case .unavailable:
                metadataFailed = true
                if let oldIndex { records[oldIndex].unavailable = true }
            }
            didRead += 1
            if ProcessInfo.processInfo.systemUptime - start > 0.25 { break }
        }
        cursor = count == 0 ? 0 : (cursor + didRead) % count
        let focused = copyElement(app, kAXFocusedWindowAttribute)
        let focusedID = focused.flatMap { element in records.first { CFEqual($0.element, element) }?.id }
        return WindowSwitcherScan(windows: records, focusedID: focusedID, unavailable: metadataFailed || didRead < count)
    }

    private enum Admission { case eligible(WindowSwitcherWindowSnapshot), excluded, unavailable }
    private func snapshot(_ window: AXUIElement, id: String) -> Admission {
        guard let values = access.windowAttributes(window), values.count == 6,
              let role = values[0] as? String else { return .unavailable }
        // A process root masquerading as a window is invalid AX data, not
        // evidence that the app has no user windows.
        if role == kAXApplicationRole as String { return .unavailable }
        guard role == kAXWindowRole as String else { return .excluded }
        if let subrole = values[1] as? String,
           ![kAXStandardWindowSubrole as String, kAXDialogSubrole as String, "AXFullScreenWindow"].contains(subrole) {
            return .excluded
        }
        guard let minimized = values[3] as? Bool,
              let point = decodePoint(values[4]),
              let size = decodeSize(values[5]) else { return .unavailable }
        guard minimized || (size.width >= 80 && size.height >= 60) else { return .excluded }
        return .eligible(WindowSwitcherWindowSnapshot(id: id, element: window, title: values[2] as? String ?? "",
                                                       minimized: minimized, bounds: CGRect(origin: point, size: size)))
    }

    private func decodePoint(_ raw: Any) -> CGPoint? {
        let value = raw as CFTypeRef
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &result) else { return nil }
        return result
    }

    private func decodeSize(_ raw: Any) -> CGSize? {
        let value = raw as CFTypeRef
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &result) else { return nil }
        return result
    }

    private func copyWindows() -> [AXUIElement]? {
        guard let values = access.windows(of: app), !values.contains(where: { CFEqual($0, app) }) else { return nil }
        return values.reduce(into: []) { result, window in
            if !result.contains(where: { CFEqual($0, window) }) { result.append(window) }
        }
    }

    private func copyElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        access.element(element, attribute: name)
    }

    func validate(_ id: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: liveWindow(id) != nil) }
        }
    }

    private func liveWindow(_ id: String, cancellation: WindowSwitcherActionCancellation? = nil,
                            retryUnavailable: Bool = false) -> AXUIElement? {
        guard !stopped, let record = records.first(where: { $0.id == id }) else { return nil }
        for attempt in 0..<(retryUnavailable ? 3 : 1) {
            guard cancellation?.isCancelled != true else { return nil }
            if let windows = copyWindows() {
                // A successful read excluding the target is authoritative.
                return windows.contains(where: { CFEqual($0, record.element) }) ? record.element : nil
            }
            if retryUnavailable && attempt < 2 { Thread.sleep(forTimeInterval: 0.04) }
        }
        return nil
    }

    private func minimizedBeforeAction(_ window: AXUIElement, cancellation: WindowSwitcherActionCancellation) -> Bool? {
        for attempt in 0..<3 {
            guard !cancellation.isCancelled else { return nil }
            if let value = access.minimized(window) { return value }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.04) }
        }
        return nil
    }

    func perform(_ id: String, close: Bool) async -> WindowSwitcherActionResult {
        let cancellation = WindowSwitcherActionCancellation()
        return await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            return await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                    guard let window = liveWindow(id, cancellation: cancellation, retryUnavailable: true) else {
                        continuation.resume(returning: cancellation.isCancelled ? .cancelled : .unavailable); return
                    }
                    guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                    if close {
                        guard let button = copyElement(window, kAXCloseButtonAttribute) else {
                            continuation.resume(returning: .unavailable); return
                        }
                        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                        let result = access.perform(button, action: kAXPressAction)
                        continuation.resume(returning: result == .success ? .requested : .failed)
                        return
                    }
                    guard let minimized = minimizedBeforeAction(window, cancellation: cancellation) else {
                        continuation.resume(returning: cancellation.isCancelled ? .cancelled : .unavailable); return
                    }
                    guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                    if minimized {
                        guard access.set(window, attribute: kAXMinimizedAttribute, value: false) == .success else {
                            continuation.resume(returning: .failed); return
                        }
                        waitForRestore(id, window: window, attempts: 12, cancellation: cancellation, continuation: continuation)
                    } else {
                        raise(id, window: window, cancellation: cancellation, continuation: continuation)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func waitForRestore(_ id: String, window: AXUIElement, attempts: Int,
                                cancellation: WindowSwitcherActionCancellation,
                                continuation: CheckedContinuation<WindowSwitcherActionResult, Never>) {
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
            guard !stopped else { continuation.resume(returning: .unavailable); return }
            // macOS may accept deminiaturization before its animation completes.
            // Observe readiness without resubmitting the restore request.
            if access.minimized(window) == false {
                guard liveWindow(id) != nil else { continuation.resume(returning: .unavailable); return }
                raise(id, window: window, cancellation: cancellation, continuation: continuation)
            } else if attempts > 1 {
                waitForRestore(id, window: window, attempts: attempts - 1, cancellation: cancellation, continuation: continuation)
            } else {
                continuation.resume(returning: .failed)
            }
        }
    }

    private func raise(_ id: String, window: AXUIElement, cancellation: WindowSwitcherActionCancellation,
                       continuation: CheckedContinuation<WindowSwitcherActionResult, Never>) {
        // Writable main/focus are hints; read-back verification is authoritative
        // for apps which implement only the raise action.
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(window, attribute: kAXMainAttribute, value: true)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(window, attribute: kAXFocusedAttribute, value: true)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        guard access.perform(window, action: kAXRaiseAction) == .success else {
            continuation.resume(returning: .failed); return
        }
        verifyFocus(id, attempts: 12, cancellation: cancellation, continuation: continuation)
    }

    private func verifyFocus(_ id: String, attempts: Int, cancellation: WindowSwitcherActionCancellation,
                             continuation: CheckedContinuation<WindowSwitcherActionResult, Never>) {
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
            guard let live = liveWindow(id) else { continuation.resume(returning: .unavailable); return }
            if let focused = copyElement(app, kAXFocusedWindowAttribute), CFEqual(focused, live) {
                continuation.resume(returning: .succeeded)
            } else if attempts > 1 {
                // Retry only the observation, never resubmit an action.
                verifyFocus(id, attempts: attempts - 1, cancellation: cancellation, continuation: continuation)
            } else {
                continuation.resume(returning: .failed)
            }
        }
    }

    private var windowNotifications: [String] {
        [kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
         kAXWindowDeminiaturizedNotification, kAXMovedNotification, kAXResizedNotification]
    }
    private func installObserver() {
        guard access.observesSystemNotifications, observer == nil else { return }
        var result: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            Unmanaged<WindowSwitcherProcessWorker>.fromOpaque(context).takeUnretainedValue().invalidated()
        }
        guard AXObserverCreate(pid, callback, &result) == .success, let result else { return }
        observer = result
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(result, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
    }
    private func observe(_ window: AXUIElement) {
        guard let observer, !observedWindows.contains(where: { CFEqual($0, window) }) else { return }
        for name in windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        observedWindows.append(window)
    }
}

@MainActor
protocol WindowSwitcherCatalog: AnyObject {
    var onChange: (() -> Void)? { get set }
    var focusedWindowID: String? { get }
    var isInitialDiscoveryComplete: Bool { get }
    func start()
    func stop()
    func refresh()
    func entries(sortMode: WindowSwitcherSortMode) -> [WindowSwitcherAppEntry]
    func activate(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult
    func closeWindow(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult
    func quitApplication(_ entry: WindowSwitcherAppEntry) -> WindowSwitcherActionResult
}

@MainActor
final class WindowSwitcherAppCatalog: WindowSwitcherCatalog {
    var onChange: (() -> Void)?
    private(set) var isInitialDiscoveryComplete = false
    private(set) var unavailableApplicationCount = 0
    var focusedWindowID: String? { recency.focusedID }
    private let notificationCenter: NotificationCenter
    private let accessFactory: @Sendable (pid_t) -> any WindowSwitcherAXAccess
    private var observers: [NSObjectProtocol] = []
    private var workers: [pid_t: WindowSwitcherProcessWorker] = [:]
    private var snapshots: [pid_t: [WindowSwitcherAppEntry]] = [:]
    private var inFlight: Set<pid_t> = []
    private var unavailable: Set<pid_t> = []
    private var recency = WindowSwitcherRecency()
    private var timer: Timer?
    private var running = false

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         accessFactory: @escaping @Sendable (pid_t) -> any WindowSwitcherAXAccess = { _ in SystemWindowSwitcherAXAccess() }) {
        self.notificationCenter = notificationCenter
        self.accessFactory = accessFactory
    }

    func start() {
        guard !running else { return }
        running = true
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh(); self?.onChange?() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        running = false
        isInitialDiscoveryComplete = false
        timer?.invalidate(); timer = nil
        observers.forEach(notificationCenter.removeObserver); observers.removeAll()
        workers.values.forEach { $0.stop() }; workers.removeAll()
        snapshots.removeAll(); inFlight.removeAll(); unavailable.removeAll()
        recency = WindowSwitcherRecency()
    }

    func refresh() {
        guard running else { return }
        guard AXIsProcessTrusted() else {
            // Notify the plugin so an open session is cancelled on revocation.
            onChange?()
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let pids = Set(apps.map(\.processIdentifier))
        for pid in Array(workers.keys) where !pids.contains(pid) {
            workers.removeValue(forKey: pid)?.stop(); snapshots.removeValue(forKey: pid)
            inFlight.remove(pid); unavailable.remove(pid)
        }
        for app in apps {
            let pid = app.processIdentifier
            let worker: WindowSwitcherProcessWorker
            if let existing = workers[pid], existing.launchDate == app.launchDate { worker = existing } else {
                workers.removeValue(forKey: pid)?.stop()
                snapshots.removeValue(forKey: pid)
                inFlight.remove(pid)
                worker = WindowSwitcherProcessWorker(pid: pid, launchDate: app.launchDate, access: accessFactory(pid)) { [weak self] in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
                workers[pid] = worker
            }
            guard inFlight.insert(pid).inserted else { continue }
            Task { [weak self] in
                let result = await worker.scan()
                guard let self, running, workers[pid] === worker else { return }
                inFlight.remove(pid)
                if result.unavailable { unavailable.insert(pid) } else { unavailable.remove(pid) }
                unavailableApplicationCount = unavailable.count
                let previous = snapshots[pid]
                var entries = result.windows.map { window in
                    var entry = WindowSwitcherAppEntry(id: window.id, processIdentifier: pid,
                        bundleIdentifier: app.bundleIdentifier, appName: app.localizedName ?? "App",
                        windowTitle: window.title, icon: app.icon, windowElement: window.element,
                        isMinimized: window.minimized, shortcutToken: nil)
                    entry.bounds = window.bounds; entry.isHidden = app.isHidden
                    entry.metadataUnavailable = window.unavailable
                    let display = displayContext(for: window.bounds)
                    entry.displayNameContext = display?.name
                    entry.displayID = display?.id
                    return entry
                }
                // A failed read is never evidence of a windowless application.
                if entries.isEmpty && !result.unavailable {
                    entries = [WindowSwitcherAppEntry(id: "app:\(worker.lifetime)", processIdentifier: pid,
                        bundleIdentifier: app.bundleIdentifier, appName: app.localizedName ?? "App",
                        windowTitle: nil, icon: app.icon, windowElement: nil, isMinimized: false, shortcutToken: nil,
                        isHidden: app.isHidden)]
                }
                if !result.windowListReadSucceeded, entries.isEmpty, let previous {
                    entries = previous.map { var entry = $0; entry.metadataUnavailable = true; return entry }
                }
                snapshots[pid] = entries
                if workers.keys.allSatisfy({ snapshots[$0] != nil }) { isInitialDiscoveryComplete = true }
                if app.isActive {
                    recency.observeForeground(entries: entries, focusedWindowID: result.focusedID, unavailable: result.unavailable)
                }
                recency.retain(Set(snapshots.values.flatMap { $0 }.map(\.id)))
                if previous != entries || app.isActive { onChange?() }
            }
        }
    }

    func entries(sortMode: WindowSwitcherSortMode) -> [WindowSwitcherAppEntry] {
        let entries = snapshots.keys.sorted().flatMap { snapshots[$0] ?? [] }
        switch sortMode {
        case .recentUse: return recency.sort(entries)
        case .fixed: return entries.sorted {
            let order = ($0.appName + $0.displayName).localizedCaseInsensitiveCompare($1.appName + $1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        }
    }

    func activate(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult {
        guard snapshots[entry.processIdentifier]?.contains(where: { $0.id == entry.id }) == true,
              let worker = workers[entry.processIdentifier],
              let app = NSRunningApplication(processIdentifier: entry.processIdentifier), !app.isTerminated else { return .unavailable }
        if entry.isWindowEntry, !(await worker.validate(entry.id)) { return .unavailable }
        guard !Task.isCancelled else { return .cancelled }
        guard workers[entry.processIdentifier] === worker else { return .unavailable }
        let prepared = await WindowSwitcherApplicationActivation.prepare(state: {
            .init(isHidden: app.isHidden,
                  isFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.processIdentifier,
                  isTerminated: app.isTerminated || self.workers[entry.processIdentifier] !== worker)
        }, request: { request in
            switch request {
            case .unhide: _ = app.unhide()
            case .activate: _ = app.activate(options: [])
            }
        })
        guard prepared == .succeeded else { return prepared }
        if !entry.isWindowEntry {
            recency.record(entry.id)
            refresh()
            return .succeeded
        }
        let result = await worker.perform(entry.id, close: false)
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.processIdentifier
        if result == .succeeded && isFrontmost { recency.record(entry.id) }
        refresh()
        return result == .succeeded && !isFrontmost ? .failed : result
    }

    func closeWindow(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult {
        guard entry.isWindowEntry, let worker = workers[entry.processIdentifier] else { return .unavailable }
        let result = await worker.perform(entry.id, close: true)
        refresh()
        return result
    }

    func quitApplication(_ entry: WindowSwitcherAppEntry) -> WindowSwitcherActionResult {
        guard snapshots[entry.processIdentifier]?.contains(where: { $0.id == entry.id }) == true,
              let app = NSRunningApplication(processIdentifier: entry.processIdentifier), !app.isTerminated else { return .unavailable }
        let requested = app.terminate()
        refresh()
        return requested ? .requested : .failed
    }

    private func displayContext(for bounds: CGRect) -> (id: UInt32, name: String)? {
        // AX uses a top-left origin. Convert screens without treating an offscreen
        // window as belonging to another Space; public AX exposes no Space ID.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.max { lhs, rhs in
            func area(_ screen: NSScreen) -> CGFloat {
                let r = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                               width: screen.frame.width, height: screen.frame.height).intersection(bounds)
                return r.isNull ? 0 : r.width * r.height
            }
            return area(lhs) < area(rhs)
        }.flatMap { screen in
            let rect = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
            guard rect.intersects(bounds),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        }
    }
}
