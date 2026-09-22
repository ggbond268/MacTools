import AppKit
import ApplicationServices
import ScreenCaptureKit
@testable import WindowSwitcherPlugin

struct TracingAXAccess: WindowSwitcherAXAccess {
    let observesSystemNotifications = true
    let system = SystemWindowSwitcherAXAccess()
    func windows(of app: AXUIElement) -> [AXUIElement]? { let r = system.windows(of: app); if r == nil { print("read-unavailable=windows") }; return r }
    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement? { let r = system.element(owner, attribute: attribute); if r == nil { print("read-unavailable=\(attribute)") }; return r }
    func windowAttributes(_ window: AXUIElement) -> [Any]? { system.windowAttributes(window) }
    func windowNumber(_ window: AXUIElement) -> CGWindowID? { system.windowNumber(window) }
    func minimized(_ window: AXUIElement) -> Bool? { let r = system.minimized(window); if r == nil { print("read-unavailable=minimized") }; return r }
    func set(_ element: AXUIElement, attribute: String, value: Bool) -> AXError { let result = system.set(element, attribute: attribute, value: value); print("set=\(attribute) value=\(value) result=\(result.rawValue)"); return result }
    func perform(_ element: AXUIElement, action: String) -> AXError { let result = system.perform(element, action: action); print("action=\(action) result=\(result.rawValue)"); return result }
}
@main struct LiveProbe {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await run()
            NSApp.terminate(nil)
        }
        application.run()
    }
    @MainActor static func run() async {
        guard AXIsProcessTrusted(), let pidString = CommandLine.arguments.dropFirst().first,
              ProcessInfo.processInfo.environment["WINDOW_SWITCHER_FIXTURE_PID"] == pidString,
              let pid = Int32(pidString), let app = NSRunningApplication(processIdentifier: pid) else {
            print("unavailable"); return
        }
        let original = NSWorkspace.shared.frontmostApplication
        let worker = WindowSwitcherProcessWorker(pid: pid, launchDate: app.launchDate, access: TracingAXAccess(), invalidated: {})
        defer { worker.stop() }
        let expected = Int(ProcessInfo.processInfo.environment["WINDOW_SWITCHER_FIXTURE_COUNT"] ?? "") ?? 0
        let discoveryStarted = ContinuousClock.now
        var ready = await worker.scan()
        while ready.windows.count != expected, discoveryStarted.duration(to: .now) < .seconds(3) {
            try? await Task.sleep(for: .milliseconds(50))
            ready = await worker.scan()
        }
        print("discoveryReady=\(ready.windows.count == expected) elapsed=\(discoveryStarted.duration(to: .now))")
        if ready.windows.count != expected {
            for window in SystemWindowSwitcherAXAccess().windows(of: AXUIElementCreateApplication(pid)) ?? [] {
                if let values = SystemWindowSwitcherAXAccess().windowAttributes(window) {
                    print("fixtureAttributes=\(values)")
                }
            }
        }
        let rawCount = SystemWindowSwitcherAXAccess().windows(of: AXUIElementCreateApplication(pid))?.count ?? -1
        var firstIDs = Set<String>()
        var snapshot = WindowSwitcherScan(windows: [], unavailable: false)
        for index in 0..<4 {
            let start = ContinuousClock.now
            snapshot = await worker.scan()
            let ids = Set(snapshot.windows.map(\.id))
            if index == 0 { firstIDs = ids }
            print("scan=\(index) raw=\(rawCount) windows=\(snapshot.windows.count) unique=\(ids.count) unavailable=\(snapshot.unavailable) titleGroups=\(Set(snapshot.windows.map(\.title)).count) elapsed=\(start.duration(to: .now)) retained=\(firstIDs.isSubset(of: ids))")
        }
        if snapshot.windows.count == 1, let window = snapshot.windows.first {
            var entry = WindowSwitcherAppEntry(id: window.id, processIdentifier: pid, bundleIdentifier: app.bundleIdentifier,
                appName: "Chrome Fixture", windowTitle: window.title, icon: nil, windowElement: window.element,
                isMinimized: window.minimized, shortcutToken: nil)
            entry.bounds = window.bounds
            let preview = WindowSwitcherPreview()
            var completed = false
            var captured = false
            preview.onChange = { image, message in
                if image != nil || message != nil { completed = true; captured = image != nil; print("previewMessage=\(message ?? "image")") }
            }
            preview.select(entry)
            let deadline = ContinuousClock.now + .seconds(5)
            while !completed, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            print("singleWindowPreview=\(captured) permission=\(preview.isPermissionGranted)")
            preview.cancel()
        }
        guard CommandLine.arguments.contains("--exercise"), snapshot.windows.count >= 2 else { return }
        // Exercise the production catalog against the isolated fixture PID.
        let catalog = WindowSwitcherAppCatalog(accessFactory: { processID in
            if processID == pid { return TracingAXAccess() }
            return SystemWindowSwitcherAXAccess()
        })
        catalog.start()
        defer { catalog.stop() }
        for _ in 0..<40 {
            catalog.refresh()
            if catalog.entries(sortMode: .recentUse).filter({ $0.processIdentifier == pid }).count == snapshot.windows.count { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let entries = catalog.entries(sortMode: .recentUse).filter { $0.processIdentifier == pid }
        print("catalogWindows=\(entries.count)")
        guard entries.count >= 2 else { return }
        let a = entries[0], b = entries[1]
        let preview = WindowSwitcherPreview()
        var previewCompleted = false, captured = false
        preview.onChange = { image, message in
            if image != nil || message != nil { previewCompleted = true; captured = image != nil }
        }
        preview.select(b)
        let previewDeadline = ContinuousClock.now + .seconds(4)
        while !previewCompleted, ContinuousClock.now < previewDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        print("multiWindowPreview=\(captured) exactID=\(b.windowNumber != nil)")
        preview.cancel()
        for target in [a, b, a] {
            let result = await catalog.activate(target)
            print("catalogActivation=\(result) exactFocus=\(catalog.focusedWindowID == target.id) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        }
        let recent = catalog.entries(sortMode: .recentUse).filter { $0.processIdentifier == pid }.prefix(2).map(\.id)
        print("mruExact=\(recent == [a.id, b.id])")
        if let external = entries.dropFirst(2).first, let element = external.windowElement {
            // Simulate an independent focus change, outside catalog.activate.
            let access = SystemWindowSwitcherAXAccess()
            _ = access.set(element, attribute: kAXMainAttribute, value: true)
            _ = access.set(element, attribute: kAXFocusedAttribute, value: true)
            let raised = access.perform(element, action: kAXRaiseAction)
            let deadline = ContinuousClock.now + .seconds(2)
            while catalog.focusedWindowID != external.id, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let recent = catalog.entries(sortMode: .recentUse).filter { $0.processIdentifier == pid }.first?.id
            print("externalFocusMRU=\(raised == .success && catalog.focusedWindowID == external.id && recent == external.id)")
            let reset = await catalog.activate(a)
            print("resetAfterExternalFocus=\(reset)")
        }
        NSApp.setActivationPolicy(.accessory)
        let overlay = WindowSwitcherOverlayController()
        let session = WindowSwitcherSession(entries: entries, selectedID: a.id, isPersistent: true, originalWindowID: a.id)
        for iteration in 0..<2 {
            let started = ContinuousClock.now
            overlay.show(session, currentPID: pid, showsPreview: false)
            print("panelShow=\(iteration) elapsed=\(started.duration(to: .now))")
            try? await Task.sleep(for: .milliseconds(100))
            let stayedFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            overlay.hide()
            try? await Task.sleep(for: .milliseconds(100))
            let focused = SystemWindowSwitcherAXAccess().element(AXUIElementCreateApplication(pid), attribute: kAXFocusedWindowAttribute)
            let sameWindow = focused.map { focus in a.windowElement.map { CFEqual($0, focus) } ?? false } ?? false
            print("cancelPreservedFrontmost=\(stayedFrontmost && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid) exactWindow=\(sameWindow)")
        }
        var entered: WindowSwitcherActionResult?
        overlay.onSelect = { target in
            overlay.hide()
            Task { @MainActor in entered = await catalog.activate(target) }
        }
        var searchSession = session
        searchSession.selectedID = b.id
        searchSession.query = "Fixture"
        overlay.show(searchSession, currentPID: pid, showsPreview: false)
        if let panel = NSApp.windows.first(where: { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible }),
           let content = panel.contentView {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            if let search = descendants(content).compactMap({ $0 as? NSSearchField }).first {
                panel.makeFirstResponder(search)
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36) { panel.sendEvent(event) }
            }
        }
        let enterDeadline = ContinuousClock.now + .seconds(3)
        while entered == nil, ContinuousClock.now < enterDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        print("searchEnter=\(entered == .succeeded) exactFocus=\(catalog.focusedWindowID == b.id)")
        overlay.hide()
        if let element = b.windowElement {
            let minimize = SystemWindowSwitcherAXAccess().set(element, attribute: kAXMinimizedAttribute, value: true)
            try? await Task.sleep(for: .milliseconds(700))
            let beforeRestore = catalog.entries(sortMode: .recentUse).filter { $0.processIdentifier == pid }
            let raw = SystemWindowSwitcherAXAccess().windows(of: AXUIElementCreateApplication(pid))
            print("beforeRestoreKnown=\(beforeRestore.contains { $0.id == b.id }) count=\(beforeRestore.count) sameHandle=\(raw?.contains { CFEqual($0, element) } ?? false)")
            let restore = await catalog.activate(b)
            let focused = SystemWindowSwitcherAXAccess().element(AXUIElementCreateApplication(pid), attribute: kAXFocusedWindowAttribute)
            print("restoreFocus=\(focused.map { CFEqual($0, element) } ?? false) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
            print("minimizeAccepted=\(minimize == .success) restore=\(restore) restored=\(SystemWindowSwitcherAXAccess().minimized(element) == false)")
        }
        try? await Task.sleep(for: .milliseconds(200))
        let hidden = app.hide()
        let hiddenAX = SystemWindowSwitcherAXAccess().set(AXUIElementCreateApplication(pid), attribute: kAXHiddenAttribute, value: true)
        try? await Task.sleep(for: .milliseconds(300))
        print("hiddenAX=\(hiddenAX.rawValue) observedHidden=\(app.isHidden)")
        let unhide = await catalog.activate(a)
        print("hideAccepted=\(hidden) activationAfterHide=\(unhide) visible=\(!app.isHidden) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        let close = await catalog.closeWindow(b)
        for _ in 0..<20 {
            catalog.refresh()
            if !catalog.entries(sortMode: .recentUse).contains(where: { $0.id == b.id }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let afterClose = catalog.entries(sortMode: .recentUse).filter { $0.processIdentifier == pid }
        print("close=\(close) removed=\(!afterClose.contains { $0.id == b.id }) remaining=\(afterClose.count)")
        if let original, original.processIdentifier != pid { _ = original.activate(options: []) }
    }
}
