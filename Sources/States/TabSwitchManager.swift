// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

enum TabSwitchDirection {
    case forward
    case backward
}

@MainActor
final class TabSwitchManager {
    private var visitHistoryTabIDs: [Int] = []
    /// Switching priority includes unvisited background tabs and is limited to five items.
    private(set) var recentTabIDs: [Int] = []
    /// Media ordering uses actual visits only, retaining every live visited tab.
    var visitedTabIDs: [Int] { visitHistoryTabIDs }
    private weak var browserState: BrowserState?

    private var session: Session?
    private var flagsMonitor: Any?
    private var windowResignObserver: NSObjectProtocol?
    private var appResignObserver: NSObjectProtocol?
    private var windowController: TabSwitchWindowController?
    private var snapshotCache: [Int: NSImage] = [:]

    struct Session {
        var candidateTabIDs: [Int]
        var selectedIndex: Int
        var isOverlayVisible: Bool
        var pendingRevealWorkItem: DispatchWorkItem?
        let anchorModifiers: NSEvent.ModifierFlags
    }

    init(browserState: BrowserState) {
        self.browserState = browserState
    }

    // MARK: - MRU History

    func recordActiveTab(_ tab: Tab) {
        guard let state = browserState else { return }
        if BrowserState.isAIChatId(tab.guidInLocalDB) { return }
        guard state.tabs.contains(where: { $0.guid == tab.guid }) else { return }

        let tabID = tab.guid
        pruneHistory()
        visitHistoryTabIDs.removeAll { $0 == tabID }
        visitHistoryTabIDs.insert(tabID, at: 0)
        recentTabIDs.removeAll { $0 == tabID }
        recentTabIDs.insert(tabID, at: 0)
        recentTabIDs = Array(recentTabIDs.prefix(TabSwitchMetrics.maxRecentTabs))
    }

    /// Admit an unvisited background tab as the next forward-switch target.
    /// Keep the focused tab first; an in-progress session retains its snapshot.
    func recordBackgroundTab(_ tab: Tab) {
        guard let state = browserState,
              !BrowserState.isAIChatId(tab.guidInLocalDB),
              state.focusingTab?.guid != tab.guid,
              state.tabs.contains(where: { $0.guid == tab.guid }),
              !recentTabIDs.contains(tab.guid),
              !visitHistoryTabIDs.contains(tab.guid) else { return }

        pruneHistory()
        if let currentTab = state.focusingTab,
           !BrowserState.isAIChatId(currentTab.guidInLocalDB),
           state.tabs.contains(where: { $0.guid == currentTab.guid }) {
            recentTabIDs.removeAll { $0 == currentTab.guid }
            recentTabIDs.insert(currentTab.guid, at: 0)
        }
        let insertionIndex = recentTabIDs.first == state.focusingTab?.guid ? 1 : 0
        recentTabIDs.insert(tab.guid, at: min(insertionIndex, recentTabIDs.count))
        recentTabIDs = Array(recentTabIDs.prefix(TabSwitchMetrics.maxRecentTabs))
    }

    func removeTab(tabID: Int) {
        visitHistoryTabIDs.removeAll { $0 == tabID }
        recentTabIDs.removeAll { $0 == tabID }
        snapshotCache.removeValue(forKey: tabID)
        guard var session else { return }
        session.candidateTabIDs.removeAll { $0 == tabID }
        if session.candidateTabIDs.isEmpty {
            cancelSession()
            return
        }
        if session.selectedIndex >= session.candidateTabIDs.count {
            session.selectedIndex = session.candidateTabIDs.count - 1
        }
        self.session = session
        if session.isOverlayVisible {
            updateOverlay()
        }
    }

    func handleExternalFocusChange() {
        if session != nil {
            cancelSession()
        }
    }

    // MARK: - Session

    func handleStep(_ direction: TabSwitchDirection, initiatingKey: ShortcutsKey?) {
        if session != nil {
            advanceSession(direction)
        } else {
            startSession(direction, initiatingKey: initiatingKey)
        }
    }

    private func startSession(_ direction: TabSwitchDirection, initiatingKey: ShortcutsKey?) {
        let candidates = buildCandidates()
        guard !candidates.isEmpty else { return }

        guard let state = browserState,
              let currentTab = state.focusingTab else { return }

        let currentIndex = candidates.firstIndex(of: currentTab.guid) ?? 0
        let initialIndex: Int
        if candidates.count == 1 {
            initialIndex = 0
        } else {
            switch direction {
            case .forward:
                initialIndex = (currentIndex + 1) % candidates.count
            case .backward:
                initialIndex = (currentIndex - 1 + candidates.count) % candidates.count
            }
        }

        // Freeze the initiating binding for this gesture. Shift can change
        // direction but never prolongs the session after its hold keys release.
        let anchor = initiatingKey?.modifiers.intersection([.command, .control, .option]) ?? []

        let revealWorkItem = DispatchWorkItem { [weak self] in
            self?.revealOverlayIfAnchorStillDown(modifiers: NSEvent.modifierFlags)
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TabSwitchMetrics.longPressThreshold,
            execute: revealWorkItem
        )

        session = Session(
            candidateTabIDs: candidates,
            selectedIndex: initialIndex,
            isOverlayVisible: false,
            pendingRevealWorkItem: revealWorkItem,
            anchorModifiers: anchor
        )
        snapshotCache.removeAll()

        // A menu invocation or a Shift-only navigation key has no hold key.
        // Execute one step immediately instead of leaving an unfinishable session.
        guard !anchor.isEmpty else {
            commitSession()
            return
        }

        installFlagsMonitor()
        installWindowResignObserver()
    }

    private func advanceSession(_ direction: TabSwitchDirection) {
        guard var session else { return }
        let count = session.candidateTabIDs.count
        guard count > 0 else { return }

        switch direction {
        case .forward:
            session.selectedIndex = (session.selectedIndex + 1) % count
        case .backward:
            session.selectedIndex = (session.selectedIndex - 1 + count) % count
        }
        self.session = session

        if session.isOverlayVisible {
            let selectedTabID = session.candidateTabIDs[safe: session.selectedIndex] ?? -1
            windowController?.updateSelection(selectedTabID: selectedTabID)
        } else {
            session.pendingRevealWorkItem?.cancel()
            self.session?.pendingRevealWorkItem = nil
            revealOverlay()
        }
    }

    private func commitSession() {
        guard let session, let state = browserState else {
            cancelSession()
            return
        }
        let candidates = session.candidateTabIDs
        let selectedIdx = session.selectedIndex
        tearDownSession()

        let resolvedTab: Tab? = {
            if let tabID = candidates[safe: selectedIdx],
               let tab = state.tabs.first(where: { $0.guid == tabID }) {
                return tab
            }
            for offset in 1..<candidates.count {
                for idx in [selectedIdx + offset, selectedIdx - offset] {
                    let wrapped = ((idx % candidates.count) + candidates.count) % candidates.count
                    if let tab = state.tabs.first(where: { $0.guid == candidates[wrapped] }) {
                        return tab
                    }
                }
            }
            return nil
        }()

        resolvedTab?.webContentWrapper?.setAsActiveTab()
    }

    func cancelSession() {
        tearDownSession()
    }

    private func tearDownSession() {
        session?.pendingRevealWorkItem?.cancel()
        session = nil
        dismissOverlay()
        removeFlagsMonitor()
        removeWindowResignObserver()
    }

    // MARK: - Pruning

    private func pruneHistory() {
        guard let state = browserState else { return }
        let validIDs = Set(state.tabs.map(\.guid))
        visitHistoryTabIDs.removeAll { !validIDs.contains($0) }
        recentTabIDs.removeAll { !validIDs.contains($0) }
    }

    private func buildCandidates() -> [Int] {
        guard browserState != nil else { return [] }
        pruneHistory()
        return recentTabIDs
    }

    // MARK: - Input Monitoring

    private func installFlagsMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func handleFlagsChanged(_ event: NSEvent) {
        guard event.type == .flagsChanged, let anchor = session?.anchorModifiers,
              let sessionWindow = browserState?.windowController?.window,
              event.window === sessionWindow
                || (event.window == nil && NSApp.keyWindow === sessionWindow) else { return }
        // Releasing any initiating hold key commits, even if another modifier
        // remains down. Additional Shift/Caps Lock never extend that lifetime.
        if event.modifierFlags.intersection(anchor) != anchor { commitSession() }
    }

    private func removeFlagsMonitor() {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }

    private func installWindowResignObserver() {
        guard let window = browserState?.windowController?.window else { return }

        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.cancelSession()
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cancelSession()
        }
    }

    private func removeWindowResignObserver() {
        if let observer = windowResignObserver {
            NotificationCenter.default.removeObserver(observer)
            windowResignObserver = nil
        }
        if let observer = appResignObserver {
            NotificationCenter.default.removeObserver(observer)
            appResignObserver = nil
        }
    }

    // MARK: - Overlay

    func revealOverlayIfAnchorStillDown(modifiers: NSEvent.ModifierFlags) {
        guard let anchor = session?.anchorModifiers else { return }
        let current = modifiers.intersection(.deviceIndependentFlagsMask)
        if current.intersection(anchor) == anchor {
            revealOverlay()
        } else {
            // A release can arrive before the monitor is installed. The
            // delayed check must finish that session instead of stranding it.
            commitSession()
        }
    }

    private func revealOverlay() {
        guard var session, !session.isOverlayVisible else { return }
        guard let state = browserState,
              let window = state.windowController?.window else { return }

        session.isOverlayVisible = true
        self.session = session

        let items = buildItems(from: session)
        let selectedTabID = session.candidateTabIDs[safe: session.selectedIndex] ?? -1
        let controller = TabSwitchWindowController(parentWindow: window)
        controller.selectionDelegate = self
        controller.update(
            items: items,
            selectedTabID: selectedTabID,
            themeProvider: state.themeContext
        )
        controller.window?.orderFront(nil)
        self.windowController = controller
    }

    private func updateOverlay() {
        guard let session, session.isOverlayVisible,
              let state = browserState,
              let controller = windowController else { return }

        let items = buildItems(from: session)
        let selectedTabID = session.candidateTabIDs[safe: session.selectedIndex] ?? -1
        controller.update(
            items: items,
            selectedTabID: selectedTabID,
            themeProvider: state.themeContext
        )
    }

    private func dismissOverlay() {
        windowController?.dismiss()
        windowController = nil
        snapshotCache.removeAll()
    }

    // MARK: - Item Building

    private func buildItems(from session: Session) -> [TabSwitchItem] {
        guard let state = browserState else { return [] }
        return session.candidateTabIDs.compactMap { tabID -> TabSwitchItem? in
            guard let tab = state.tabs.first(where: { $0.guid == tabID }) else { return nil }
            let snapshot = resolveSnapshot(for: tab)
            let liveFavicon = resolveLiveFaviconImage(for: tab)
            let pageURL = tab.url.flatMap { $0.isEmpty ? nil : $0 }
            return TabSwitchItem(
                tabID: tabID,
                title: tab.title,
                snapshotImage: snapshot,
                liveFaviconImage: liveFavicon,
                faviconPageURL: pageURL,
                isCurrentTab: tab.guid == state.focusingTab?.guid
            )
        }
    }

    private func resolveSnapshot(for tab: Tab) -> NSImage? {
        if let cached = snapshotCache[tab.guid] {
            return cached
        }

        let image: NSImage?

        // Live AppKit capture can return a blank image for Chromium's remote surface.
        // Use the cached thumbnail for both foreground and background tabs, as drag previews do.
        if let jpegData = ChromiumLauncher.sharedInstance().bridge?.thumbnail(forTab: Int64(tab.guid)),
           let thumb = NSImage(data: jpegData) {
            image = thumb
        } else {
            let favicon = resolveFaviconForSnapshot(for: tab) ?? NSImage()
            image = TabDraggingSession.makeTabPlaceholderSnapshot(favicon: favicon, title: tab.title)
        }

        if let image {
            snapshotCache[tab.guid] = image
        }
        return image
    }

    private func resolveLiveFaviconImage(for tab: Tab) -> NSImage? {
        guard let data = tab.liveFaviconData, let image = NSImage(data: data) else { return nil }
        return image
    }

    private func resolveFaviconForSnapshot(for tab: Tab) -> NSImage? {
        if let data = tab.liveFaviconData ?? tab.cachedFaviconData, let image = NSImage(data: data) {
            return image
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }
}

// MARK: - TabSwitchWindowControllerDelegate

extension TabSwitchManager: TabSwitchWindowControllerDelegate {
    func tabSwitchWindowDidClickItem(tabID: Int) {
        guard var session,
              let index = session.candidateTabIDs.firstIndex(of: tabID) else { return }
        session.selectedIndex = index
        self.session = session
        commitSession()
    }

    func tabSwitchWindowDidHoverItem(tabID: Int) {
        guard var session,
              let index = session.candidateTabIDs.firstIndex(of: tabID) else { return }
        session.selectedIndex = index
        self.session = session
        windowController?.updateSelection(selectedTabID: tabID)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
