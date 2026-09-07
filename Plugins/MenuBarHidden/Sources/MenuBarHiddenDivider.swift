// SPDX-License-Identifier: GPL-3.0-only
// Copyright (Ice) © 2023–2025 Jordan Baird
// Copyright (Thaw) © 2026 Toni Förster
// Licensed under the GNU GPLv3.
// Adapted from Thaw / Ice; see Sources/Resources/ThirdPartyNotices/manifest.json.
// Restored and adapted for MacTools on 2026-09-07.

import AppKit
import Combine
import MacToolsPluginKit

// MARK: - MenuBarHiddenDivider
//
// Owns one section-divider NSStatusItem. When `expand()` is called, the
// divider grows to `MenuBarHiddenConstants.dividerExpandedLength`, which
// pushes every status item to its LEFT off-screen. This mirrors Thaw's hidden
// and always-hidden `ControlItem` behavior.
//
// How it works (mirrors Thaw/Ice's ControlItem):
//   1. After creation, we find the NSLayoutConstraint in the status bar window
//      whose `secondItem` is `button.superview` (the internal container view).
//      Activating this constraint forces the window to expand to
//      `dividerExpandedLength` points, overriding AutoLayout's default sizing.
//   2. We ALSO set `statusItem.length` to the same value as a belt-and-suspenders
//      signal to NSStatusBar.
//   3. On collapse, we deactivate the constraint, set a visible divider width,
//      and call `setContentSize` so the separator itself remains visible.
//
@MainActor
final class MenuBarHiddenDivider {
    enum Kind {
        case hidden
        case alwaysHidden

        var autosaveName: String {
            switch self {
            case .hidden:
                MenuBarControlItemDefaults.hiddenAutosaveName
            case .alwaysHidden:
                MenuBarControlItemDefaults.alwaysHiddenAutosaveName
            }
        }

        var logName: String {
            switch self {
            case .hidden: "hidden"
            case .alwaysHidden: "always-hidden"
            }
        }

        func prepare(preferredPosition: Double?) {
            switch self {
            case .hidden:
                MenuBarControlItemDefaults.prepareHiddenDividerControlItem(
                    preferredPosition: preferredPosition
                        ?? MenuBarControlItemDefaults.preferredPositionForHiddenDividerLeftOfVisibleControlItem()
                )
            case .alwaysHidden:
                MenuBarControlItemDefaults.prepareAlwaysHiddenDividerControlItem()
            }
        }

        func preferredPositionForRecovery() -> Double? {
            switch self {
            case .hidden:
                MenuBarControlItemDefaults.preferredPositionForHiddenDividerLeftOfVisibleControlItem()
            case .alwaysHidden:
                nil
            }
        }

        func setPreferredPositionForRecovery(_ position: Double?) {
            switch self {
            case .hidden:
                MenuBarControlItemDefaults.setHiddenDividerControlItemPreferredPosition(position)
            case .alwaysHidden:
                break
            }
        }
    }

    /// Fires when the divider window's screen frame changes.
    var onFrameChange: (() -> Void)?

    /// CGWindowID of the divider's backing window (when installed).
    private(set) var windowID: CGWindowID?
    var hiddenControlWindowIDs: Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        if let windowID {
            ids.insert(windowID)
        }
        for item in spacerItems {
            guard let number = item.button?.window?.windowNumber, number > 0, let id = CGWindowID(exactly: number) else {
                continue
            }
            ids.insert(id)
        }
        return ids
    }

    private(set) var isInstalled = false
    private(set) var isExpanded = false
    private(set) var isVisibleDivider = false
    var screenFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    private let kind: Kind
    private var statusItem: NSStatusItem?
    private var widthConstraint: NSLayoutConstraint?
    private var centerYConstraint: NSLayoutConstraint?
    private var windowObserver: AnyCancellable?
    private var frameObserver: AnyCancellable?
    private var spacerItems: [NSStatusItem] = []

    init(kind: Kind) {
        self.kind = kind
    }

    // MARK: - Install / uninstall

    func install(preferredPosition: Double? = nil) {
        guard !isInstalled else { return }

        kind.prepare(preferredPosition: preferredPosition)
        PluginPresentationSafety.prepareForWindowOrdering()
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = kind.autosaveName

        if let button = item.button {
            configureButton(button)
            observeWindow(for: item)
            bindWindow(button.window, for: button)
        }

        statusItem = item
        isInstalled = true
        showSection(isDragging: false)
        updateWindowID()
        DispatchQueue.main.async { [weak self] in
            self?.updateWindowID()
            self?.onFrameChange?()
        }
        MenuBarHiddenLog.plugin.debug(
            "\(self.kind.logName) divider installed windowID=\(self.windowID ?? 0) hasConstraint=\(self.widthConstraint != nil)"
        )
    }

    func uninstall() {
        guard isInstalled, let item = statusItem else { return }
        frameObserver?.cancel()
        frameObserver = nil
        windowObserver?.cancel()
        windowObserver = nil
        removeSpacerItems()
        PluginPresentationSafety.prepareForWindowOrdering()
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        widthConstraint = nil
        centerYConstraint = nil
        windowID = nil
        isInstalled = false
        isExpanded = false
        isVisibleDivider = false
        MenuBarHiddenLog.plugin.debug("\(self.kind.logName) divider uninstalled")
    }

    func reinstall() {
        let shouldHide = isExpanded
        let targetPosition = kind.preferredPositionForRecovery()
        kind.setPreferredPositionForRecovery(targetPosition)
        uninstall()
        kind.setPreferredPositionForRecovery(targetPosition)
        install(preferredPosition: targetPosition)
        if shouldHide {
            hideSection()
        } else {
            showSection(isDragging: false)
        }
    }

    func refreshWindowID() {
        updateWindowID()
    }

    // MARK: - State

    /// Expands the divider so items to its left are pushed off-screen.
    func expand() {
        hideSection()
        MenuBarHiddenLog.plugin.debug(
            "\(self.kind.logName) divider expanded (constraintActive=\(self.widthConstraint?.isActive ?? false))"
        )
    }

    /// Shows the divider so hidden items become visible again.
    func collapse() {
        showSection(isDragging: false)
        MenuBarHiddenLog.plugin.debug("\(self.kind.logName) divider shown")
    }

    func hideSection() {
        updateVisibility(.hidden)
    }

    func showSection(isDragging: Bool) {
        updateVisibility(.shown)
    }

    // MARK: - Helpers

    private func configureButton(_ button: NSStatusBarButton) {
        button.title = ""
        button.image = nil
        button.isEnabled = false
        button.appearsDisabled = true
        button.isHighlighted = false
        button.alphaValue = 0
    }

    private func observeWindow(for item: NSStatusItem) {
        windowObserver = item.publisher(for: \.button, options: [.initial, .new])
            .compactMap { $0 }
            .flatMap { button in
                button.publisher(for: \.window, options: [.initial, .new]).map { window in (button, window) }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] button, window in
                self?.bindWindow(window, for: button)
            }
    }

    private func bindWindow(_ window: NSWindow?, for button: NSStatusBarButton) {
        guard let window else {
            frameObserver?.cancel()
            frameObserver = nil
            updateWindowID()
            return
        }

        if widthConstraint == nil {
            widthConstraint = findWidthConstraint(for: button)
        }
        widthConstraint?.isActive = isExpanded

        if centerYConstraint == nil, let contentView = window.contentView {
            let constraint = button.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
            constraint.isActive = true
            centerYConstraint = constraint
        }

        frameObserver?.cancel()
        frameObserver = window.publisher(for: \.frame)
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowID()
                self?.onFrameChange?()
            }
        updateWindowID()
    }

    private func findWidthConstraint(for button: NSStatusBarButton) -> NSLayoutConstraint? {
        guard let contentView = button.window?.contentView else {
            return nil
        }

        let container = button.superview
        return contentView
            .constraintsAffectingLayout(for: .horizontal)
            .first { $0.secondItem === container }
    }

    private func updateVisibility(_ state: State) {
        guard isInstalled, let item = statusItem else { return }

        configureButtonForState(state)

        if state == .hidden {
            widthConstraint?.isActive = true
            item.length = MenuBarHiddenConstants.dividerExpandedLength
            updateSpacerItems()
            isExpanded = true
            isVisibleDivider = false
        } else {
            removeSpacerItems()
            widthConstraint?.isActive = false
            item.length = MenuBarHiddenConstants.dividerVisibleLength
            shrinkWindow(for: item, width: state.windowWidth)
            isExpanded = false
            isVisibleDivider = true
        }
        updateWindowID()
        DispatchQueue.main.async { [weak self] in
            self?.updateWindowID()
            self?.onFrameChange?()
        }
    }

    private func configureButtonForState(_ state: State) {
        guard let button = statusItem?.button else { return }
        button.image = nil
        button.isHighlighted = false
        button.title = state == .shown ? "|" : ""
        button.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        switch state {
        case .hidden:
            button.isEnabled = false
            button.appearsDisabled = true
            button.alphaValue = 0
        case .shown:
            button.isEnabled = true
            button.appearsDisabled = false
            button.alphaValue = 1
        }
    }

    private func shrinkWindow(for item: NSStatusItem, width: CGFloat) {
        guard let window = item.button?.window else { return }
        var size = window.frame.size
        size.width = width
        window.setContentSize(size)
    }

    private func updateSpacerItems() {
        let needed = requiredSpacerCount()
        guard needed > 0 else {
            removeSpacerItems()
            return
        }

        if spacerItems.count != needed {
            removeSpacerItems()
            spacerItems = (0..<needed).map { index in
                PluginPresentationSafety.prepareForWindowOrdering()
                let item = NSStatusBar.system.statusItem(withLength: 0)
                item.autosaveName = "\(kind.autosaveName).Spacer.\(index)"

                if let button = item.button {
                    configureButton(button)
                }

                return item
            }
        }

        spacerItems.forEach { $0.length = MenuBarHiddenConstants.dividerExpandedLength }
    }

    private func removeSpacerItems() {
        for item in spacerItems {
            PluginPresentationSafety.prepareForWindowOrdering()
            NSStatusBar.system.removeStatusItem(item)
        }
        spacerItems.removeAll()
    }

    private func requiredSpacerCount() -> Int {
        let maxScreenWidth = NSScreen.screens.map(\.frame.width).max() ?? 6000
        guard maxScreenWidth > 5120 else { return 0 }

        let desiredWidth = maxScreenWidth * 3
        let remaining = desiredWidth - MenuBarHiddenConstants.dividerExpandedLength
        guard remaining > 0 else { return 0 }

        return Int(ceil(remaining / MenuBarHiddenConstants.dividerExpandedLength))
    }

    private func updateWindowID() {
        guard let window = statusItem?.button?.window else {
            windowID = nil
            return
        }
        let number = window.windowNumber
        guard number > 0, let id = CGWindowID(exactly: number) else {
            windowID = nil
            return
        }
        windowID = id
    }

    private enum State {
        case hidden
        case shown

        var windowWidth: CGFloat {
            switch self {
            case .hidden:
                MenuBarHiddenConstants.dividerExpandedLength
            case .shown:
                MenuBarHiddenConstants.dividerVisibleLength
            }
        }
    }
}
